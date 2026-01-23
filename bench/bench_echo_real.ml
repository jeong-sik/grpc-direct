(** Real Echo Server/Client Benchmark

    This runs an actual gRPC echo server and client in the same process
    to measure real latency including network stack overhead.

    Usage:
      dune exec bench/bench_echo_real.exe
*)

open Printf

(** Benchmark configuration *)
let port = 50099
let requests = 10000
let warmup = 500
let payload_size = 100

(** Statistics *)
type stats = {
  mutable count : int;
  mutable total_ns : int64;
  mutable min_ns : int64;
  mutable max_ns : int64;
  latencies : int64 array;
}

let create_stats size = {
  count = 0;
  total_ns = 0L;
  min_ns = Int64.max_int;
  max_ns = 0L;
  latencies = Array.make size 0L;
}

let record_latency stats latency_ns =
  if stats.count < Array.length stats.latencies then begin
    stats.latencies.(stats.count) <- latency_ns;
    stats.count <- stats.count + 1;
    stats.total_ns <- Int64.add stats.total_ns latency_ns;
    if latency_ns < stats.min_ns then stats.min_ns <- latency_ns;
    if latency_ns > stats.max_ns then stats.max_ns <- latency_ns
  end

let percentile stats p =
  if stats.count = 0 then 0L
  else begin
    let sorted = Array.sub stats.latencies 0 stats.count in
    Array.sort Int64.compare sorted;
    let idx = int_of_float (float_of_int (stats.count - 1) *. p) in
    sorted.(idx)
  end

let ns_to_us ns = Int64.to_float ns /. 1000.0
let _ns_to_ms ns = Int64.to_float ns /. 1_000_000.0

(** Simple echo server handler *)
let echo_handler _addr (reqd : H2.Reqd.t) =
  let request = H2.Reqd.request reqd in
  let path = request.target in

  if String.equal path "/echo.EchoService/Echo" then begin
    (* Read request body *)
    let body = H2.Reqd.request_body reqd in
    let chunks = ref [] in

    let rec read_body () =
      H2.Body.Reader.schedule_read body
        ~on_eof:(fun () ->
          (* Echo back the request *)
          let request_data = String.concat "" (List.rev !chunks) in
          let response = H2.Response.create
            ~headers:(H2.Headers.of_list [
              "content-type", "application/grpc+proto";
              "grpc-status", "0";
            ])
            `OK
          in
          let response_body = H2.Reqd.respond_with_streaming reqd response in
          H2.Body.Writer.write_string response_body request_data;
          H2.Body.Writer.close response_body
        )
        ~on_read:(fun bs ~off ~len ->
          chunks := Bigstringaf.substring bs ~off ~len :: !chunks;
          read_body ()
        )
    in
    read_body ()
  end
  else begin
    (* Unknown method *)
    let response = H2.Response.create
      ~headers:(H2.Headers.of_list ["grpc-status", "12"])
      `OK
    in
    H2.Reqd.respond_with_string reqd response ""
  end

let error_handler _addr ?request:_ _error _respond =
  ()

(** Run benchmark *)
let run_benchmark env =
  let net = Eio.Stdenv.net env in

  printf "\n╔═══════════════════════════════════════════════════════╗\n";
  printf "║     grpc-direct REAL Echo Benchmark (Server + Client)    ║\n";
  printf "╚═══════════════════════════════════════════════════════╝\n\n";

  printf "Configuration:\n";
  printf "  Port:      %d\n" port;
  printf "  Requests:  %d\n" requests;
  printf "  Warmup:    %d\n" warmup;
  printf "  Payload:   %d bytes\n\n%!" payload_size;

  Eio.Switch.run @@ fun sw ->

  (* Start server in background *)
  let server_ready, resolve_ready = Eio.Promise.create () in

  Eio.Fiber.fork ~sw (fun () ->
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true net addr in
    Eio.Promise.resolve resolve_ready ();

    while true do
      Eio.Net.accept_fork ~sw socket ~on_error:(fun _ -> ())
        (fun client_socket client_addr ->
          Eio.Switch.run @@ fun inner_sw ->
          H2_eio.Server.create_connection_handler
            ~request_handler:echo_handler
            ~error_handler
            ~sw:inner_sw
            client_addr
            client_socket)
    done
  );

  (* Wait for server to be ready *)
  Eio.Promise.await server_ready;
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.1;
  printf "Server started on port %d\n\n%!" port;

  (* Connect client *)
  let target = sprintf "http://127.0.0.1:%d" port in
  let client = Grpc_eio.Client.connect ~sw ~env target in

  let payload = String.init payload_size (fun i -> Char.chr (65 + (i mod 26))) in

  (* Warmup *)
  printf "Warming up with %d requests...\n%!" warmup;
  for _ = 1 to warmup do
    match Grpc_eio.Client.call_unary ~sw ~env client
      ~service:"echo.EchoService"
      ~method_:"Echo"
      ~request:payload with
    | Ok _ -> ()
    | Error _ -> ()
  done;

  (* Benchmark *)
  printf "Running %d requests...\n\n%!" requests;
  let stats = create_stats requests in
  let total_start = Mtime_clock.elapsed_ns () in

  for _ = 1 to requests do
    let start = Mtime_clock.elapsed_ns () in
    let _ = Grpc_eio.Client.call_unary ~sw ~env client
      ~service:"echo.EchoService"
      ~method_:"Echo"
      ~request:payload in
    let elapsed = Int64.sub (Mtime_clock.elapsed_ns ()) start in
    record_latency stats elapsed
  done;

  let total_elapsed = Int64.sub (Mtime_clock.elapsed_ns ()) total_start in
  let total_secs = Int64.to_float total_elapsed /. 1_000_000_000.0 in
  let rps = float_of_int stats.count /. total_secs in

  Grpc_eio.Client.close client;

  (* Print results *)
  printf "═══════════════════════════════════════════════════════\n";
  printf "                    RESULTS\n";
  printf "═══════════════════════════════════════════════════════\n\n";

  printf "Throughput:\n";
  printf "  Requests:    %d\n" stats.count;
  printf "  Total time:  %.2f s\n" total_secs;
  printf "  RPS:         %.0f requests/sec\n\n" rps;

  printf "Latency (µs):\n";
  printf "  Min:  %8.2f\n" (ns_to_us stats.min_ns);
  printf "  Avg:  %8.2f\n" (ns_to_us (Int64.div stats.total_ns (Int64.of_int stats.count)));
  printf "  P50:  %8.2f\n" (ns_to_us (percentile stats 0.50));
  printf "  P90:  %8.2f\n" (ns_to_us (percentile stats 0.90));
  printf "  P99:  %8.2f\n" (ns_to_us (percentile stats 0.99));
  printf "  Max:  %8.2f\n\n" (ns_to_us stats.max_ns);

  printf "═══════════════════════════════════════════════════════\n";
  printf "  grpc-direct: %.0f RPS, P50=%.0f µs, P99=%.0f µs\n"
    rps (ns_to_us (percentile stats 0.50)) (ns_to_us (percentile stats 0.99));
  printf "═══════════════════════════════════════════════════════\n\n%!";

  (* Comparison note *)
  printf "To compare with Go grpc:\n";
  printf "  1. Install ghz: go install github.com/bojand/ghz/cmd/ghz@latest\n";
  printf "  2. Run: ghz --insecure --call echo.EchoService/Echo \\\n";
  printf "          -d '{\"message\":\"hello\"}' -n %d localhost:%d\n\n%!" requests port;

  ()

let () =
  Eio_main.run run_benchmark
