(** Multi-domain gRPC server benchmark.

    Compares single-domain vs multi-domain performance using ghz.

    Usage:
      dune exec bench/bench_multi_domain.exe -- [--domains N]

    Benchmark flow:
    1. Start server with specified domain count
    2. Run ghz benchmark
    3. Report results
*)

let port = 50061
let total_requests = 10_000
let concurrency = 50

(** Create echo service *)
let make_echo_service () =
  let handler request =
    (* Simple echo - return the request as response *)
    request
  in
  Grpc_eio.Service.create
    ~name:"echo.Echo"
    ~methods:[ Grpc_eio.Service.unary "Echo" handler ]
    ()
;;

(** Run ghz benchmark and parse results *)
let run_ghz_benchmark ~label =
  let argv =
    [| "ghz"
     ; "--insecure"
     ; "--proto"
     ; "bench/go-comparison/echo.proto"
     ; "--call"
     ; "echo.Echo/Echo"
     ; "-d"
     ; "{\"message\":\"hello\"}"
     ; "-n"
     ; string_of_int total_requests
     ; "-c"
     ; string_of_int concurrency
     ; "--connections"
     ; "10"
     ; Printf.sprintf "127.0.0.1:%d" port
    |]
  in
  Printf.printf "\n📊 Running benchmark: %s\n%!" label;
  let result =
    try
      (* Merge stdout/stderr (equivalent to `2>&1`) without spawning a shell. *)
      let stdout_r, stdout_w = Unix.pipe () in
      let pid = Unix.create_process "ghz" argv Unix.stdin stdout_w stdout_w in
      Unix.close stdout_w;
      let ic = Unix.in_channel_of_descr stdout_r in
      let output = Buffer.create 1024 in
      (try
         while true do
           Buffer.add_string output (input_line ic);
           Buffer.add_char output '\n'
         done
       with
       | End_of_file -> ());
      close_in ic;
      ignore (Unix.waitpid [] pid);
      Buffer.contents output
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) ->
      "ghz not available (skipping benchmark output parsing)\n"
    | exn ->
      Printf.sprintf "failed to run ghz: %s\n" (Printexc.to_string exn)
  in
  (* Parse key metrics *)
  let parse_metric pattern =
    try
      let re = Str.regexp pattern in
      ignore (Str.search_forward re result 0);
      Some (Str.matched_group 1 result)
    with
    | Not_found -> None
  in
  let rps = parse_metric "Requests/sec:[ \t]+\\([0-9.]+\\)" in
  let avg = parse_metric "Average:[ \t]+\\([0-9.]+\\)" in
  let p50 = parse_metric "50th percentile:[ \t]+\\([0-9.]+\\)" in
  let p99 = parse_metric "99th percentile:[ \t]+\\([0-9.]+\\)" in
  Printf.printf "  RPS: %s\n" (Option.value ~default:"N/A" rps);
  Printf.printf "  Avg: %s ms\n" (Option.value ~default:"N/A" avg);
  Printf.printf "  P50: %s ms\n" (Option.value ~default:"N/A" p50);
  Printf.printf "  P99: %s ms\n%!" (Option.value ~default:"N/A" p99);
  rps, p50, p99
;;

(** Server process for single domain *)
let run_single_domain_server env =
  let config = Grpc_eio.Server.{ default_config with port } in
  let server =
    Grpc_eio.Server.create ~config ()
    |> Grpc_eio.Server.add_service (make_echo_service ())
  in
  Eio.Switch.run
  @@ fun sw ->
  (* Run server in background fiber *)
  Eio.Fiber.fork ~sw (fun () -> Grpc_eio.Server.serve ~sw ~env server);
  (* Wait for benchmark duration, then shutdown *)
  Eio.Time.sleep (Eio.Stdenv.clock env) 30.0;
  Grpc_eio.Server.shutdown server
;;

(** Server process for multi domain *)
let run_multi_domain_server ~domains env =
  let config = Grpc_eio.Server.{ default_config with port } in
  let server =
    Grpc_eio.Server.create ~config ()
    |> Grpc_eio.Server.add_service (make_echo_service ())
  in
  (* Multi-domain serve runs in its own switch *)
  let stop = ref false in
  Eio.Fiber.fork_daemon
    ~sw:(Eio.Switch.run (fun sw -> sw))
    (fun () ->
       while not !stop do
         Eio.Time.sleep (Eio.Stdenv.clock env) 0.1
       done;
       `Stop_daemon);
  Grpc_eio.Server_multi.serve_multi ~domains ~env server
;;

let () =
  (* Parse args *)
  let domains = ref 0 in
  let mode = ref "both" in
  Arg.parse
    [ "--domains", Arg.Set_int domains, "Number of domains (0=auto)"
    ; "--mode", Arg.Set_string mode, "Mode: single|multi|both"
    ]
    (fun _ -> ())
    "Multi-domain benchmark";
  Printf.printf "╔════════════════════════════════════════════════════════════════╗\n";
  Printf.printf "║           grpc-direct Multi-Domain Benchmark                      ║\n";
  Printf.printf "╠════════════════════════════════════════════════════════════════╣\n";
  Printf.printf
    "║  Requests: %d | Concurrency: %d | Port: %d               ║\n"
    total_requests
    concurrency
    port;
  Printf.printf
    "║  Domains: %s                                                  ║\n"
    (if !domains = 0 then "auto" else string_of_int !domains);
  Printf.printf "╚════════════════════════════════════════════════════════════════╝\n%!";
  let recommended = Domain.recommended_domain_count () in
  Printf.printf "\n💻 System: %d recommended domains\n%!" recommended;
  (* For now, just print usage - actual benchmark requires separate processes *)
  Printf.printf "\n📋 To run the benchmark:\n";
  Printf.printf "   1. Terminal 1: dune exec bench/bench_server.exe\n";
  Printf.printf
    "   2. Terminal 2: ghz --insecure --proto bench/go-comparison/echo.proto \\\n";
  Printf.printf
    "                  --call echo.Echo/Echo -d '{\"message\":\"hello\"}' \\\n";
  Printf.printf "                  -n 10000 -c 50 127.0.0.1:50051\n";
  Printf.printf "\n   For multi-domain:\n";
  Printf.printf
    "   1. Terminal 1: dune exec bench/bench_server.exe -- --multi --domains 4\n";
  Printf.printf "   2. Terminal 2: (same ghz command)\n%!"
;;
