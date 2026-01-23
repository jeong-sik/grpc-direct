(** Benchmarks for gRPC codec operations.
    Run: dune exec bench/bench_codec.exe *)

let time_it name iterations f =
  let start = Unix.gettimeofday () in
  for _ = 1 to iterations do
    ignore (f ())
  done;
  let elapsed = Unix.gettimeofday () -. start in
  let per_op = elapsed /. float_of_int iterations *. 1_000_000.0 in
  Printf.printf "%-30s %8d ops  %8.2f µs/op  %8.0f ops/sec\n%!"
    name iterations per_op (float_of_int iterations /. elapsed)

let random_string len =
  String.init len (fun _ -> Char.chr (Random.int 256))

let () =
  Printf.printf "\n=== grpc-direct Benchmarks ===\n\n%!";
  Printf.printf "%-30s %8s  %12s  %12s\n%!" "Benchmark" "Iters" "Latency" "Throughput";
  Printf.printf "%s\n%!" (String.make 70 '-');

  (* Message encoding *)
  let small_msg = random_string 100 in
  let medium_msg = random_string 1024 in
  let large_msg = random_string 65536 in
  let codec = Grpc_core.Codec.identity in

  time_it "encode 100B (identity)" 100_000 (fun () ->
    Grpc_core.Message.encode ~codec small_msg
  );

  time_it "encode 1KB (identity)" 50_000 (fun () ->
    Grpc_core.Message.encode ~codec medium_msg
  );

  time_it "encode 64KB (identity)" 10_000 (fun () ->
    Grpc_core.Message.encode ~codec large_msg
  );

  (* gzip compression *)
  let gzip = Grpc_core.Codec.gzip () in

  time_it "encode 1KB (gzip)" 10_000 (fun () ->
    Grpc_core.Message.encode ~codec:gzip medium_msg
  );

  time_it "encode 64KB (gzip)" 1_000 (fun () ->
    Grpc_core.Message.encode ~codec:gzip large_msg
  );

  (* Decode benchmarks - unwrap Result for setup *)
  let encoded_small = match Grpc_core.Message.encode ~codec small_msg with
    | Ok s -> s | Error e -> failwith e in
  let encoded_medium = match Grpc_core.Message.encode ~codec medium_msg with
    | Ok s -> s | Error e -> failwith e in
  let encoded_gzip = match Grpc_core.Message.encode ~codec:gzip medium_msg with
    | Ok s -> s | Error e -> failwith e in

  time_it "decode 100B (identity)" 100_000 (fun () ->
    Grpc_core.Message.decode ~codec encoded_small
  );

  time_it "decode 1KB (identity)" 50_000 (fun () ->
    Grpc_core.Message.decode ~codec encoded_medium
  );

  time_it "decode 1KB (gzip)" 10_000 (fun () ->
    Grpc_core.Message.decode ~codec:gzip encoded_gzip
  );

  (* Status creation *)
  time_it "Status.ok" 500_000 (fun () ->
    Grpc_core.Status.ok
  );

  time_it "Status.error" 500_000 (fun () ->
    Grpc_core.Status.error Grpc_core.Status.Internal "error"
  );

  (* Timeout parsing *)
  time_it "Timeout.parse" 500_000 (fun () ->
    Grpc_core.Timeout.parse "30S"
  );

  time_it "Timeout.to_string" 500_000 (fun () ->
    Grpc_core.Timeout.to_string Grpc_core.Timeout.default
  );

  Printf.printf "\n=== Benchmark Complete ===\n%!"
