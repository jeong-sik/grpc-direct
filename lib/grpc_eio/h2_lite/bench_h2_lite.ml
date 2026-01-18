(** Benchmark for H2_lite module

    Measures:
    1. Buffer pool acquire/release throughput
    2. Frame parsing speed
    3. gRPC message encoding/decoding
    4. Comparison with standard allocation
*)

open H2_lite

let iterations = 1_000_000

(** Measure time in microseconds *)
let time_us f =
  let t0 = Unix.gettimeofday () in
  f ();
  let t1 = Unix.gettimeofday () in
  (t1 -. t0) *. 1_000_000.

(** Benchmark buffer pool vs standard allocation *)
let bench_buffer_pool () =
  Printf.printf "\n=== Buffer Pool Benchmark ===\n";

  (* Warm up the pool *)
  Buffer_pool.prewarm ~count_per_class:16;

  (* Pooled allocation *)
  let pooled_time = time_us (fun () ->
    for _ = 1 to iterations do
      let buf = Buffer_pool.acquire ~size:1024 in
      Buffer_pool.release buf
    done
  ) in

  (* Standard allocation *)
  let standard_time = time_us (fun () ->
    for _ = 1 to iterations do
      let _buf = Bytes.create 1024 in
      ()  (* GC will collect *)
    done
  ) in

  let stats = Buffer_pool.stats () in

  Printf.printf "Iterations: %d\n" iterations;
  Printf.printf "Pooled:   %.2f µs total, %.4f µs/op\n" pooled_time (pooled_time /. float iterations);
  Printf.printf "Standard: %.2f µs total, %.4f µs/op\n" standard_time (standard_time /. float iterations);
  Printf.printf "Speedup:  %.2fx\n" (standard_time /. pooled_time);
  Printf.printf "Pool hit rate: %.2f%%\n" (stats.hit_rate *. 100.)

(** Benchmark frame parsing *)
let bench_frame_parsing () =
  Printf.printf "\n=== Frame Parsing Benchmark ===\n";

  (* Create a sample DATA frame *)
  let payload = Cstruct.create 100 in
  let frame = Frame.make_data ~stream_id:1l ~end_stream:false payload in
  let serialized = Frame.to_cstruct frame in

  (* Parse many times *)
  let parse_time = time_us (fun () ->
    for _ = 1 to iterations do
      match Frame.parse serialized with
      | Some _ -> ()
      | None -> failwith "Parse failed"
    done
  ) in

  Printf.printf "Iterations: %d\n" iterations;
  Printf.printf "Parse time: %.2f µs total, %.4f µs/op\n" parse_time (parse_time /. float iterations);
  Printf.printf "Throughput: %.2f M frames/sec\n" (float iterations /. parse_time)

(** Benchmark frame serialization *)
let bench_frame_serialization () =
  Printf.printf "\n=== Frame Serialization Benchmark ===\n";

  let payload = Cstruct.create 100 in

  (* Serialize many times *)
  let serialize_time = time_us (fun () ->
    for _ = 1 to iterations do
      let frame = Frame.make_data ~stream_id:1l ~end_stream:false payload in
      let _serialized = Frame.to_cstruct frame in
      ()
    done
  ) in

  Printf.printf "Iterations: %d\n" iterations;
  Printf.printf "Serialize time: %.2f µs total, %.4f µs/op\n" serialize_time (serialize_time /. float iterations);
  Printf.printf "Throughput: %.2f M frames/sec\n" (float iterations /. serialize_time)

(** Benchmark gRPC message encoding *)
let bench_grpc_message () =
  Printf.printf "\n=== gRPC Message Encoding Benchmark ===\n";

  let body = Cstruct.create 100 in

  (* Encode many times *)
  let encode_time = time_us (fun () ->
    for _ = 1 to iterations do
      let _encoded = Grpc_message.encode body in
      ()
    done
  ) in

  Printf.printf "Iterations: %d\n" iterations;
  Printf.printf "Encode time: %.2f µs total, %.4f µs/op\n" encode_time (encode_time /. float iterations);
  Printf.printf "Throughput: %.2f M msgs/sec\n" (float iterations /. encode_time)

(** Benchmark complete request cycle (headers + data) *)
let bench_request_cycle () =
  Printf.printf "\n=== Request Cycle Benchmark (headers + data) ===\n";

  let body = Cstruct.create 100 in
  let headers_buf = Cstruct.create 256 in

  let cycle_time = time_us (fun () ->
    for i = 1 to iterations do
      let stream_id = Int32.of_int (i * 2 + 1) in

      (* Encode headers *)
      let headers_len = Hpack_lite.encode_request_headers
        ~scheme:"http"
        ~authority:"localhost:50051"
        ~path:"/echo.EchoService/Echo"
        ~content_type:"application/grpc+proto"
        headers_buf
      in
      let headers = Cstruct.sub headers_buf 0 headers_len in

      (* Create HEADERS frame *)
      let _hf = Frame.make_headers ~stream_id ~end_stream:false ~end_headers:true headers in

      (* Encode body *)
      let encoded_body = Grpc_message.encode body in

      (* Create DATA frame *)
      let _df = Frame.make_data ~stream_id ~end_stream:true encoded_body in
      ()
    done
  ) in

  Printf.printf "Iterations: %d\n" iterations;
  Printf.printf "Cycle time: %.2f µs total, %.4f µs/op\n" cycle_time (cycle_time /. float iterations);
  Printf.printf "Throughput: %.2f M req/sec (encoding only)\n" (float iterations /. cycle_time)

(** Compare pooled vs non-pooled frame serialization *)
let bench_pooled_vs_alloc () =
  Printf.printf "\n=== Pooled vs Standard Allocation (Frame Serialization) ===\n";

  let payload = Cstruct.create 1000 in
  let frame = Frame.make_data ~stream_id:1l ~end_stream:false payload in

  (* With pooled buffers *)
  Buffer_pool.prewarm ~count_per_class:16;
  let pooled_time = time_us (fun () ->
    for _ = 1 to iterations do
      let serialized = Frame.to_cstruct_pooled frame in
      Buffer_pool.Cstruct_pool.release serialized
    done
  ) in

  (* With standard allocation *)
  let alloc_time = time_us (fun () ->
    for _ = 1 to iterations do
      let _serialized = Frame.to_cstruct frame in
      ()
    done
  ) in

  Printf.printf "Iterations: %d\n" iterations;
  Printf.printf "Pooled:   %.2f µs total, %.4f µs/op\n" pooled_time (pooled_time /. float iterations);
  Printf.printf "Standard: %.2f µs total, %.4f µs/op\n" alloc_time (alloc_time /. float iterations);
  Printf.printf "Speedup:  %.2fx\n" (alloc_time /. pooled_time)

let () =
  Printf.printf "H2_lite Benchmark\n";
  Printf.printf "=================\n";

  bench_buffer_pool ();
  bench_frame_parsing ();
  bench_frame_serialization ();
  bench_grpc_message ();
  bench_request_cycle ();
  bench_pooled_vs_alloc ();

  Printf.printf "\n=== Summary ===\n";
  let stats = Buffer_pool.stats () in
  Printf.printf "Total buffers allocated: %d\n" stats.total_allocated;
  Printf.printf "Total buffers recycled: %d\n" stats.total_recycled;
  Printf.printf "Final hit rate: %.2f%%\n" (stats.hit_rate *. 100.)
