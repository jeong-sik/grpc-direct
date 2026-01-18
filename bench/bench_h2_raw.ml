(** Raw HTTP/2 Performance Benchmark

    Tests pure HTTP/2 + H2 library performance without gRPC framing.
    This gives us a baseline for network overhead.
*)

open Printf

let port = 50098
let _requests = 10000
let _warmup = 100
let payload = String.make 100 'A'

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

(** Measure pure message encode/decode speed *)
let bench_codec () =
  printf "\n=== Codec Benchmark (No Network) ===\n";
  let codec = Grpc_core.Codec.identity in
  let stats = create_stats 100000 in

  for _ = 1 to 100000 do
    let start = Mtime_clock.elapsed_ns () in
    let encoded = Grpc_core.Message.encode ~codec payload in
    let _ = match encoded with
      | Ok data -> Grpc_core.Message.decode ~codec data
      | Error _ -> Error "encode failed"
    in
    let elapsed = Int64.sub (Mtime_clock.elapsed_ns ()) start in
    record_latency stats elapsed
  done;

  printf "  Cycles:  %d\n" stats.count;
  printf "  Avg:     %.2f µs\n" (ns_to_us (Int64.div stats.total_ns (Int64.of_int stats.count)));
  printf "  P50:     %.2f µs\n" (ns_to_us (percentile stats 0.50));
  printf "  P99:     %.2f µs\n\n%!" (ns_to_us (percentile stats 0.99));

  stats

(** Measure header building speed *)
let bench_headers () =
  printf "=== Header Building Benchmark ===\n";
  let stats = create_stats 100000 in

  for _ = 1 to 100000 do
    let start = Mtime_clock.elapsed_ns () in
    let headers = H2.Headers.of_list [
      ":method", "POST";
      ":scheme", "http";
      ":path", "/echo.EchoService/Echo";
      ":authority", "localhost:50051";
      "content-type", "application/grpc+proto";
      "te", "trailers";
      "grpc-timeout", "30S";
      "authorization", "Bearer token123";
    ] in
    ignore headers;
    let elapsed = Int64.sub (Mtime_clock.elapsed_ns ()) start in
    record_latency stats elapsed
  done;

  printf "  Cycles:  %d\n" stats.count;
  printf "  Avg:     %.2f µs\n" (ns_to_us (Int64.div stats.total_ns (Int64.of_int stats.count)));
  printf "  P50:     %.2f µs\n" (ns_to_us (percentile stats 0.50));
  printf "  P99:     %.2f µs\n\n%!" (ns_to_us (percentile stats 0.99));

  stats

(** Measure TCP connection setup time *)
let bench_tcp_connect env =
  printf "=== TCP Connection Benchmark ===\n";
  let net = Eio.Stdenv.net env in
  let stats = create_stats 100 in

  (* Start a simple listener *)
  Eio.Switch.run @@ fun sw ->
  let server_ready, resolve_ready = Eio.Promise.create () in

  Eio.Fiber.fork ~sw (fun () ->
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true net addr in
    Eio.Promise.resolve resolve_ready ();

    for _ = 1 to 100 do
      let client, _ = Eio.Net.accept ~sw socket in
      Eio.Flow.close client
    done
  );

  Eio.Promise.await server_ready;

  for _ = 1 to 100 do
    let start = Mtime_clock.elapsed_ns () in
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    let client = Eio.Net.connect ~sw net addr in
    Eio.Flow.close client;
    let elapsed = Int64.sub (Mtime_clock.elapsed_ns ()) start in
    record_latency stats elapsed
  done;

  printf "  Connections: %d\n" stats.count;
  printf "  Avg:         %.2f µs\n" (ns_to_us (Int64.div stats.total_ns (Int64.of_int stats.count)));
  printf "  P50:         %.2f µs\n" (ns_to_us (percentile stats 0.50));
  printf "  P99:         %.2f µs\n\n%!" (ns_to_us (percentile stats 0.99));

  stats

(** Print summary *)
let print_summary codec_stats header_stats tcp_stats =
  printf "╔═══════════════════════════════════════════════════════╗\n";
  printf "║           grpc-eio Component Breakdown                ║\n";
  printf "╚═══════════════════════════════════════════════════════╝\n\n";

  let codec_p50 = ns_to_us (percentile codec_stats 0.50) in
  let header_p50 = ns_to_us (percentile header_stats 0.50) in
  let tcp_p50 = ns_to_us (percentile tcp_stats 0.50) in
  let total = codec_p50 +. header_p50 +. tcp_p50 in

  printf "Component Latency (P50):\n";
  printf "  ┌───────────────────┬───────────┬────────┐\n";
  printf "  │ Component         │ Time (µs) │ %%      │\n";
  printf "  ├───────────────────┼───────────┼────────┤\n";
  printf "  │ Codec (enc+dec)   │ %9.2f │ %5.1f%% │\n" codec_p50 (codec_p50 /. total *. 100.0);
  printf "  │ Header building   │ %9.2f │ %5.1f%% │\n" header_p50 (header_p50 /. total *. 100.0);
  printf "  │ TCP connect       │ %9.2f │ %5.1f%% │\n" tcp_p50 (tcp_p50 /. total *. 100.0);
  printf "  ├───────────────────┼───────────┼────────┤\n";
  printf "  │ TOTAL (per-call)  │ %9.2f │ 100.0%% │\n" total;
  printf "  └───────────────────┴───────────┴────────┘\n\n";

  (* Estimate RPS *)
  let estimated_rps = 1_000_000.0 /. total in
  printf "Estimated throughput: ~%.0f RPS (single connection)\n\n" estimated_rps;

  printf "Note: Real gRPC calls add:\n";
  printf "  - HTTP/2 framing overhead\n";
  printf "  - gRPC message framing (5 bytes)\n";
  printf "  - Server processing time\n";
  printf "  - Response decoding\n\n";

  printf "Typical expected performance:\n";
  printf "  - Unary call P50: ~50-100 µs (localhost)\n";
  printf "  - Throughput: ~10,000-30,000 RPS (single connection)\n%!"

let () =
  printf "\n╔═══════════════════════════════════════════════════════╗\n";
  printf "║      grpc-eio Raw Performance Benchmark               ║\n";
  printf "╚═══════════════════════════════════════════════════════╝\n\n";

  let codec_stats = bench_codec () in
  let header_stats = bench_headers () in

  Eio_main.run @@ fun env ->
  let tcp_stats = bench_tcp_connect env in

  print_summary codec_stats header_stats tcp_stats;

  printf "\n=== Benchmark Complete ===\n%!"
