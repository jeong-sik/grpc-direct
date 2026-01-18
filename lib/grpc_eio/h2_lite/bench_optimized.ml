(** Benchmark for optimized H2_lite module

    Measures the performance improvements from:
    1. Native int Huffman decoder (vs Int64)
    2. O(1) Huffman lookup tables (vs O(256) search)
    3. Ring buffer pool (vs weak ref list)
    4. O(1) HPACK static table lookup (vs O(61) search)
*)

open H2_lite

let iterations = 100_000

(** Measure time in milliseconds *)
let time_ms f =
  let t0 = Unix.gettimeofday () in
  f ();
  let t1 = Unix.gettimeofday () in
  (t1 -. t0) *. 1000.

(** Benchmark Huffman encoding/decoding *)
let bench_huffman () =
  Printf.printf "\n=== Huffman Encoding/Decoding Benchmark ===\n";

  (* Typical gRPC header values *)
  let test_strings = [
    "/echo.EchoService/Echo";
    "application/grpc+proto";
    "localhost:50051";
    "trailers";
    "identity";
    "grpc-status";
  ] in

  (* Encode all strings *)
  let encoded = List.map Hpack.Huffman.encode test_strings in

  (* Benchmark encoding *)
  let encode_time = time_ms (fun () ->
    for _ = 1 to iterations do
      List.iter (fun s -> ignore (Hpack.Huffman.encode s)) test_strings
    done
  ) in

  (* Benchmark decoding *)
  let decode_time = time_ms (fun () ->
    for _ = 1 to iterations do
      List.iter (fun e -> ignore (Hpack.Huffman.decode e)) encoded
    done
  ) in

  let total_ops = iterations * List.length test_strings in
  Printf.printf "Iterations: %d per string, %d total ops\n" iterations total_ops;
  Printf.printf "Encode: %.2f ms total, %.4f µs/op\n" encode_time (encode_time *. 1000. /. float total_ops);
  Printf.printf "Decode: %.2f ms total, %.4f µs/op\n" decode_time (decode_time *. 1000. /. float total_ops);

  (* Show compression *)
  Printf.printf "\nCompression ratios:\n";
  List.iter2 (fun orig enc ->
    let ratio = float (String.length enc) /. float (String.length orig) *. 100. in
    Printf.printf "  %s: %d -> %d bytes (%.1f%%)\n"
      (String.sub orig 0 (min 20 (String.length orig)))
      (String.length orig) (String.length enc) ratio
  ) test_strings encoded

(** Benchmark buffer pool *)
let bench_buffer_pool () =
  Printf.printf "\n=== Buffer Pool (Ring Buffer) Benchmark ===\n";

  Buffer_pool.prewarm ~count_per_class:8;

  let pool_time = time_ms (fun () ->
    for _ = 1 to iterations * 10 do
      let buf = Buffer_pool.acquire ~size:1024 in
      Buffer_pool.release buf
    done
  ) in

  let alloc_time = time_ms (fun () ->
    for _ = 1 to iterations * 10 do
      ignore (Bytes.create 1024)
    done
  ) in

  let ops = iterations * 10 in
  let stats = Buffer_pool.stats () in

  Printf.printf "Iterations: %d\n" ops;
  Printf.printf "Pooled:   %.2f ms total, %.4f µs/op\n" pool_time (pool_time *. 1000. /. float ops);
  Printf.printf "Standard: %.2f ms total, %.4f µs/op\n" alloc_time (alloc_time *. 1000. /. float ops);
  Printf.printf "Speedup:  %.2fx\n" (alloc_time /. pool_time);
  Printf.printf "Hit rate: %.2f%%\n" (stats.hit_rate *. 100.)

(** Benchmark HPACK static table lookup *)
let bench_hpack_static () =
  Printf.printf "\n=== HPACK Static Table Lookup Benchmark ===\n";

  let headers = [
    (":method", "POST");
    (":scheme", "http");
    (":path", "/");
    (":status", "200");
    ("content-type", "");  (* Name only *)
    ("accept-encoding", "gzip, deflate");
  ] in

  let lookup_time = time_ms (fun () ->
    for _ = 1 to iterations * 10 do
      List.iter (fun (name, _value) ->
        ignore (Hpack.lookup_static_name name)
      ) headers
    done
  ) in

  let ops = iterations * 10 * List.length headers in
  Printf.printf "Iterations: %d lookups\n" ops;
  Printf.printf "Lookup time: %.2f ms total, %.4f µs/op\n" lookup_time (lookup_time *. 1000. /. float ops)

(** Benchmark Frame parsing *)
let bench_frame_parsing () =
  Printf.printf "\n=== Frame Parsing Benchmark ===\n";

  let payload = Cstruct.create 100 in
  let frame = Frame.make_data ~stream_id:1l ~end_stream:false payload in
  let serialized = Frame.to_cstruct frame in

  let parse_time = time_ms (fun () ->
    for _ = 1 to iterations * 10 do
      ignore (Frame.parse serialized)
    done
  ) in

  let ops = iterations * 10 in
  Printf.printf "Iterations: %d\n" ops;
  Printf.printf "Parse time: %.2f ms total, %.4f µs/op\n" parse_time (parse_time *. 1000. /. float ops);
  Printf.printf "Throughput: %.2f M frames/sec\n" (float ops /. parse_time /. 1000.)

(** Benchmark HPACK full encode *)
let bench_hpack_encode () =
  Printf.printf "\n=== HPACK Full Encode Benchmark ===\n";

  let ctx = Hpack.create () in
  let headers = [
    (":method", "POST");
    (":scheme", "http");
    (":path", "/echo.EchoService/Echo");
    (":authority", "localhost:50051");
    ("content-type", "application/grpc");
    ("te", "trailers");
  ] in

  let encode_time = time_ms (fun () ->
    for _ = 1 to iterations do
      ignore (Hpack.encode ctx headers)
    done
  ) in

  Printf.printf "Iterations: %d\n" iterations;
  Printf.printf "Encode time: %.2f ms total, %.4f µs/op\n" encode_time (encode_time *. 1000. /. float iterations);
  Printf.printf "Throughput: %.2f K encodes/sec\n" (float iterations /. encode_time)

let () =
  Printf.printf "╔═══════════════════════════════════════════════════════╗\n";
  Printf.printf "║     H2_lite Optimized Performance Benchmark           ║\n";
  Printf.printf "╚═══════════════════════════════════════════════════════╝\n";

  bench_huffman ();
  bench_buffer_pool ();
  bench_hpack_static ();
  bench_frame_parsing ();
  bench_hpack_encode ();

  Printf.printf "\n=== Performance Summary ===\n";
  Printf.printf "Key optimizations applied:\n";
  Printf.printf "  ✓ Native int Huffman decoder (vs Int64)\n";
  Printf.printf "  ✓ O(1) Huffman lookup table (vs O(256) search)\n";
  Printf.printf "  ✓ Ring buffer pool (vs weak ref list)\n";
  Printf.printf "  ✓ O(1) HPACK static table (vs O(61) search)\n"
