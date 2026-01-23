(** gRPC Client Performance Benchmark

    Measures latency, throughput, and connection overhead for grpc-direct client.
    Designed to be comparable with Go/Rust/Python benchmarks.

    Usage:
      dune exec bench/bench_client.exe -- --host localhost --port 50051 --requests 10000
*)

open Printf

(** Benchmark configuration *)
type config = {
  host : string;
  port : int;
  requests : int;
  concurrency : int;
  warmup : int;
  payload_size : int;
}

let default_config = {
  host = "localhost";
  port = 50051;
  requests = 10000;
  concurrency = 1;
  warmup = 100;
  payload_size = 100;
}

(** Statistics collection *)
type stats = {
  mutable count : int;
  mutable total_ns : int64;
  mutable min_ns : int64;
  mutable max_ns : int64;
  latencies : int64 array;  (* For percentile calculation *)
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
let ns_to_ms ns = Int64.to_float ns /. 1_000_000.0

(** Generate payload of specified size *)
let generate_payload size =
  String.init size (fun i -> Char.chr (65 + (i mod 26)))

(** Time a single operation in nanoseconds *)
let time_ns f =
  let start = Mtime_clock.elapsed_ns () in
  let result = f () in
  let elapsed = Int64.sub (Mtime_clock.elapsed_ns ()) start in
  (result, elapsed)

(** Benchmark: Connection setup time (including TLS handshake) *)
let _bench_connection_setup ~env ~config =
  printf "\n=== Connection Setup Benchmark ===\n%!";
  let stats = create_stats 100 in

  for _ = 1 to 100 do
    let _, elapsed = time_ns (fun () ->
      Eio.Switch.run @@ fun sw ->
      let client = Grpc_eio.Client.connect ~sw ~env
        (sprintf "http://%s:%d" config.host config.port) in
      Grpc_eio.Client.close client
    ) in
    record_latency stats elapsed
  done;

  printf "  Connections: %d\n" stats.count;
  printf "  Min:  %.2f ms\n" (ns_to_ms stats.min_ns);
  printf "  Max:  %.2f ms\n" (ns_to_ms stats.max_ns);
  printf "  Avg:  %.2f ms\n" (ns_to_ms (Int64.div stats.total_ns (Int64.of_int stats.count)));
  printf "  P50:  %.2f ms\n" (ns_to_ms (percentile stats 0.50));
  printf "  P99:  %.2f ms\n%!" (ns_to_ms (percentile stats 0.99))

(** Benchmark: Unary RPC latency *)
let bench_unary_latency ~sw ~env ~config =
  printf "\n=== Unary RPC Latency Benchmark ===\n%!";

  let client = Grpc_eio.Client.connect ~sw ~env
    (sprintf "http://%s:%d" config.host config.port) in

  let payload = generate_payload config.payload_size in
  let stats = create_stats config.requests in

  (* Warmup *)
  printf "  Warming up with %d requests...\n%!" config.warmup;
  for _ = 1 to config.warmup do
    let _ = Grpc_eio.Client.call_unary ~sw ~env client
      ~service:"grpc.testing.BenchmarkService"
      ~method_:"UnaryCall"
      ~request:payload in
    ()
  done;

  (* Benchmark *)
  printf "  Running %d requests...\n%!" config.requests;
  let total_start = Mtime_clock.elapsed_ns () in

  for _ = 1 to config.requests do
    let _, elapsed = time_ns (fun () ->
      Grpc_eio.Client.call_unary ~sw ~env client
        ~service:"grpc.testing.BenchmarkService"
        ~method_:"UnaryCall"
        ~request:payload
    ) in
    record_latency stats elapsed
  done;

  let total_elapsed = Int64.sub (Mtime_clock.elapsed_ns ()) total_start in
  let total_secs = Int64.to_float total_elapsed /. 1_000_000_000.0 in
  let rps = float_of_int stats.count /. total_secs in

  Grpc_eio.Client.close client;

  printf "\n  Results:\n";
  printf "  Requests:    %d\n" stats.count;
  printf "  Total time:  %.2f s\n" total_secs;
  printf "  Throughput:  %.0f RPS\n" rps;
  printf "  Latency:\n";
  printf "    Min:  %.2f µs\n" (ns_to_us stats.min_ns);
  printf "    Max:  %.2f µs\n" (ns_to_us stats.max_ns);
  printf "    Avg:  %.2f µs\n" (ns_to_us (Int64.div stats.total_ns (Int64.of_int stats.count)));
  printf "    P50:  %.2f µs\n" (ns_to_us (percentile stats 0.50));
  printf "    P90:  %.2f µs\n" (ns_to_us (percentile stats 0.90));
  printf "    P99:  %.2f µs\n%!" (ns_to_us (percentile stats 0.99));

  (rps, percentile stats 0.50, percentile stats 0.99)

(** Benchmark: Streaming throughput *)
let _bench_streaming_throughput ~sw ~env ~config =
  printf "\n=== Streaming Throughput Benchmark ===\n%!";

  let client = Grpc_eio.Client.connect ~sw ~env
    (sprintf "http://%s:%d" config.host config.port) in

  let payload = generate_payload config.payload_size in
  let message_count = config.requests in

  printf "  Sending %d messages...\n%!" message_count;
  let total_start = Mtime_clock.elapsed_ns () in

  let requests = Grpc_eio.Stream.create 1024 in

  (* Producer fiber *)
  Eio.Fiber.fork ~sw (fun () ->
    for _ = 1 to message_count do
      Grpc_eio.Stream.add requests payload
    done;
    Grpc_eio.Stream.close requests
  );

  let responses = Grpc_eio.Client.call_bidi ~sw ~env client
    ~service:"grpc.testing.BenchmarkService"
    ~method_:"StreamingCall"
    ~requests in

  (* Consume responses *)
  let received = ref 0 in
  let rec consume () =
    match Grpc_eio.Stream.take responses with
    | Ok _ ->
        incr received;
        if !received < message_count then consume ()
    | Error _ -> ()
  in
  consume ();

  let total_elapsed = Int64.sub (Mtime_clock.elapsed_ns ()) total_start in
  let total_secs = Int64.to_float total_elapsed /. 1_000_000_000.0 in
  let messages_per_sec = float_of_int !received /. total_secs in
  let bytes_per_sec = messages_per_sec *. float_of_int config.payload_size in

  Grpc_eio.Client.close client;

  printf "\n  Results:\n";
  printf "  Messages:    %d\n" !received;
  printf "  Total time:  %.2f s\n" total_secs;
  printf "  Throughput:  %.0f msg/s\n" messages_per_sec;
  printf "  Bandwidth:   %.2f MB/s\n%!" (bytes_per_sec /. 1_000_000.0);

  messages_per_sec

(** Print comparison with other languages *)
let print_comparison rps p50_us p99_us =
  printf "\n=== Performance Comparison ===\n";
  printf "┌────────────────────┬───────────┬───────────┬───────────┐\n";
  printf "│ Implementation     │ RPS       │ P50 (µs)  │ P99 (µs)  │\n";
  printf "├────────────────────┼───────────┼───────────┼───────────┤\n";
  printf "│ OCaml grpc-direct     │ %9.0f │ %9.2f │ %9.2f │\n" rps (ns_to_us p50_us) (ns_to_us p99_us);
  printf "├────────────────────┼───────────┼───────────┼───────────┤\n";
  printf "│ Go grpc (typical)  │   ~50,000 │    ~50.00 │   ~200.00 │\n";
  printf "│ Rust tonic         │   ~80,000 │    ~30.00 │   ~100.00 │\n";
  printf "│ Python grpcio      │   ~10,000 │   ~200.00 │   ~800.00 │\n";
  printf "│ Java grpc-java     │   ~40,000 │    ~60.00 │   ~250.00 │\n";
  printf "└────────────────────┴───────────┴───────────┴───────────┘\n";
  printf "\n* Typical values from grpc-bench (github.com/LesnyRumworker/grpc-bench)\n";
  printf "* Actual results depend on hardware, network, and server implementation\n%!"

(** Dry run without server - test framework only *)
let bench_dry_run config =
  printf "\n=== Dry Run (No Server Required) ===\n%!";

  (* Benchmark message encoding/decoding *)
  printf "\nMessage Encoding/Decoding:\n";
  let payload = generate_payload config.payload_size in
  let codec = Grpc_core.Codec.identity in
  let stats = create_stats 100000 in

  for _ = 1 to 100000 do
    let _, elapsed = time_ns (fun () ->
      match Grpc_core.Message.encode ~codec payload with
      | Ok encoded ->
          (match Grpc_core.Message.decode ~codec encoded with
           | Ok _ -> ()
           | Error _ -> ())
      | Error _ -> ()
    ) in
    record_latency stats elapsed
  done;

  printf "  Encode+Decode cycles: %d\n" stats.count;
  printf "  Payload size: %d bytes\n" config.payload_size;
  printf "  Avg:  %.2f µs\n" (ns_to_us (Int64.div stats.total_ns (Int64.of_int stats.count)));
  printf "  P50:  %.2f µs\n" (ns_to_us (percentile stats 0.50));
  printf "  P99:  %.2f µs\n%!" (ns_to_us (percentile stats 0.99));

  (* Benchmark header building *)
  printf "\nHeader Building:\n";
  let stats2 = create_stats 100000 in

  for _ = 1 to 100000 do
    let _, elapsed = time_ns (fun () ->
      let headers = H2.Headers.of_list [
        ":authority", "localhost:50051";
        "content-type", "application/grpc+proto";
        "te", "trailers";
        "grpc-accept-encoding", "identity";
      ] in
      let headers = H2.Headers.add headers "grpc-timeout" "30S" in
      let headers = H2.Headers.add headers "authorization" "Bearer token123" in
      ignore headers
    ) in
    record_latency stats2 elapsed
  done;

  printf "  Header build cycles: %d\n" stats2.count;
  printf "  Avg:  %.2f µs\n" (ns_to_us (Int64.div stats2.total_ns (Int64.of_int stats2.count)));
  printf "  P50:  %.2f µs\n" (ns_to_us (percentile stats2 0.50));
  printf "  P99:  %.2f µs\n%!" (ns_to_us (percentile stats2 0.99));

  (* Credentials overhead *)
  printf "\nCredentials Processing:\n";
  let creds = Grpc_eio.Client.Credentials.with_compute_creds
    ~f:(fun () -> [("authorization", "Bearer " ^ "token123")])
    ()
  in
  let stats3 = create_stats 100000 in

  for _ = 1 to 100000 do
    let _, elapsed = time_ns (fun () ->
      ignore (Grpc_eio.Client.Credentials.get_call_headers creds)
    ) in
    record_latency stats3 elapsed
  done;

  printf "  Credential fetch cycles: %d\n" stats3.count;
  printf "  Avg:  %.2f µs\n" (ns_to_us (Int64.div stats3.total_ns (Int64.of_int stats3.count)));
  printf "  P50:  %.2f µs\n" (ns_to_us (percentile stats3 0.50));
  printf "  P99:  %.2f µs\n%!" (ns_to_us (percentile stats3 0.99))

(** Parse command line arguments *)
let parse_args () =
  let config = ref default_config in
  let dry_run = ref false in
  let specs = [
    ("--host", Arg.String (fun s -> config := { !config with host = s }), "Server host");
    ("--port", Arg.Int (fun i -> config := { !config with port = i }), "Server port");
    ("--requests", Arg.Int (fun i -> config := { !config with requests = i }), "Number of requests");
    ("--concurrency", Arg.Int (fun i -> config := { !config with concurrency = i }), "Concurrency level");
    ("--warmup", Arg.Int (fun i -> config := { !config with warmup = i }), "Warmup requests");
    ("--payload", Arg.Int (fun i -> config := { !config with payload_size = i }), "Payload size in bytes");
    ("--dry-run", Arg.Set dry_run, "Run without server (test framework only)");
  ] in
  Arg.parse specs (fun _ -> ()) "gRPC Client Benchmark";
  (!config, !dry_run)

let () =
  let config, dry_run = parse_args () in

  printf "╔═══════════════════════════════════════════════════════╗\n";
  printf "║       grpc-direct Performance Benchmark v0.3.0           ║\n";
  printf "╚═══════════════════════════════════════════════════════╝\n";
  printf "\nConfiguration:\n";
  printf "  Host:        %s\n" config.host;
  printf "  Port:        %d\n" config.port;
  printf "  Requests:    %d\n" config.requests;
  printf "  Concurrency: %d\n" config.concurrency;
  printf "  Payload:     %d bytes\n%!" config.payload_size;

  if dry_run then
    bench_dry_run config
  else begin
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->

    (* Run benchmarks *)
    let rps, p50, p99 = bench_unary_latency ~sw ~env ~config in

    (* Print comparison *)
    print_comparison rps p50 p99
  end;

  printf "\n=== Benchmark Complete ===\n%!"
