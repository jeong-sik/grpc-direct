(** Standalone Echo Server for Benchmarking

    This server runs independently, allowing fair comparison with:
    - grpc-direct client
    - ghz (Go gRPC benchmarking tool)

    Supports both single-domain and multi-domain modes for scaling benchmarks.

    Usage:
      # Single domain (default):
      dune exec bench/bench_server.exe

      # Multi-domain (4 domains):
      dune exec bench/bench_server.exe -- --multi --domains 4

      # Multi-domain (auto-detect):
      dune exec bench/bench_server.exe -- --multi

      # Then run benchmark:
      ghz --insecure --proto bench/go-comparison/echo.proto \
          --call echo.Echo/Echo -d '{"message":"hello"}' \
          -n 10000 -c 50 127.0.0.1:50099
*)

open Printf

let port = 50099

(** High-performance buffer with exponential growth.
    Based on ocaml-grpc's Buffer pattern:
    - Power-of-2 capacity scaling (O(log n) reallocations)
    - Direct blit from Bigstringaf (memcpy-based, near zero-copy)
    - No list reversal or string concatenation overhead *)
module StreamBuffer = struct
  type t = { mutable contents : bytes; mutable length : int }

  let create ?(capacity = 1024) () =
    { contents = Bytes.create capacity; length = 0 }

  let _length t = t.length
  let capacity t = Bytes.length t.contents

  let rec nearest_power_of_2 acc target =
    if acc >= target then acc else nearest_power_of_2 (acc * 2) target

  let ensure_size t ~extra =
    let current_capacity = capacity t in
    let needed_capacity = t.length + extra in
    if needed_capacity > current_capacity then begin
      let new_capacity = nearest_power_of_2 current_capacity needed_capacity in
      let new_contents = Bytes.create new_capacity in
      Bytes.blit t.contents 0 new_contents 0 t.length;
      t.contents <- new_contents
    end

  let append_bigstringaf t bs ~off ~len =
    ensure_size t ~extra:len;
    Bigstringaf.blit_to_bytes bs ~src_off:off t.contents ~dst_off:t.length ~len;
    t.length <- t.length + len

  let to_string t = Bytes.sub_string t.contents 0 t.length

  let _reset t = t.length <- 0
end

(** gRPC message framing helpers *)
module GrpcFrame = struct
  (** Decode gRPC frame: [1 byte flag][4 bytes length][payload] *)
  let decode data =
    if String.length data < 5 then
      None
    else
      let len =
        (Char.code data.[1] lsl 24) lor
        (Char.code data.[2] lsl 16) lor
        (Char.code data.[3] lsl 8) lor
        Char.code data.[4]
      in
      if String.length data < 5 + len then
        None
      else
        Some (String.sub data 5 len)

  (** Encode gRPC frame: [0x00][4 bytes length][payload] *)
  let encode payload =
    let len = String.length payload in
    let frame = Bytes.create (5 + len) in
    Bytes.set frame 0 '\x00';  (* not compressed *)
    Bytes.set_uint16_be frame 1 (len lsr 16);
    Bytes.set_uint16_be frame 3 (len land 0xFFFF);
    Bytes.blit_string payload 0 frame 5 len;
    Bytes.to_string frame
end

(** Echo handler - properly handles gRPC framing *)
let echo_handler _addr (reqd : H2.Reqd.t) =
  let request = H2.Reqd.request reqd in
  let path = request.target in

  if String.equal path "/echo.EchoService/Echo" then begin
    let body = H2.Reqd.request_body reqd in
    (* Use StreamBuffer instead of chunks list - O(1) amortized append *)
    let buffer = StreamBuffer.create ~capacity:256 () in

    let rec read_body () =
      H2.Body.Reader.schedule_read body
        ~on_eof:(fun () ->
          let request_data = StreamBuffer.to_string buffer in

          (* Decode gRPC frame, echo payload, re-encode *)
          let response_payload = match GrpcFrame.decode request_data with
            | Some payload -> GrpcFrame.encode payload  (* Echo back the payload *)
            | None -> GrpcFrame.encode ""  (* Empty response on decode failure *)
          in

          let response = H2.Response.create
            ~headers:(H2.Headers.of_list [
              "content-type", "application/grpc+proto";
            ])
            `OK
          in
          let response_body = H2.Reqd.respond_with_streaming reqd response in
          H2.Body.Writer.write_string response_body response_payload;

          (* Schedule trailers with grpc-status BEFORE closing *)
          H2.Reqd.schedule_trailers reqd (H2.Headers.of_list [
            "grpc-status", "0";
            "grpc-message", "";
          ]);

          H2.Body.Writer.close response_body
        )
        ~on_read:(fun bs ~off ~len ->
          (* Direct blit from Bigstringaf - memcpy-based, no intermediate allocations *)
          StreamBuffer.append_bigstringaf buffer bs ~off ~len;
          read_body ()
        )
    in
    read_body ()
  end
  else begin
    let response = H2.Response.create
      ~headers:(H2.Headers.of_list [
        "content-type", "application/grpc+proto";
        "grpc-status", "12";  (* UNIMPLEMENTED *)
      ])
      `OK
    in
    H2.Reqd.respond_with_string reqd response ""
  end

let error_handler _addr ?request:_ _error _respond = ()

(** Single-domain server *)
let run_single_domain env =
  let net = Eio.Stdenv.net env in

  printf "\n╔═══════════════════════════════════════════════════════╗\n";
  printf "║       grpc-direct Echo Server (Single Domain)            ║\n";
  printf "╚═══════════════════════════════════════════════════════╝\n\n";

  printf "Server listening on port %d\n" port;
  printf "Press Ctrl+C to stop\n\n";
  printf "Test with:\n";
  printf "  ghz --insecure --proto bench/go-comparison/echo.proto \\\n";
  printf "      --call echo.Echo/Echo -d '{\"message\":\"hello\"}' \\\n";
  printf "      -n 10000 -c 50 127.0.0.1:%d\n\n%!" port;

  Eio.Switch.run @@ fun sw ->
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true net addr in

  printf "Server ready (single domain). Waiting for connections...\n%!";

  while true do
    Eio.Net.accept_fork ~sw socket ~on_error:(fun exn ->
      printf "Connection error: %s\n%!" (Printexc.to_string exn))
      (fun client_socket client_addr ->
        Eio.Switch.run @@ fun inner_sw ->
        H2_eio.Server.create_connection_handler
          ~request_handler:echo_handler
          ~error_handler
          ~sw:inner_sw
          client_addr
          client_socket)
  done

(** Multi-domain server using SO_REUSEPORT *)
let run_multi_domain ~domains env =
  let num_domains =
    if domains > 0 then domains
    else max 1 (Domain.recommended_domain_count () - 1)
  in

  printf "\n╔═══════════════════════════════════════════════════════╗\n";
  printf "║       grpc-direct Echo Server (Multi-Domain)             ║\n";
  printf "╚═══════════════════════════════════════════════════════╝\n\n";

  printf "Server listening on port %d with %d domains\n" port num_domains;
  printf "System recommended: %d domains\n" (Domain.recommended_domain_count ());
  printf "Press Ctrl+C to stop\n\n";
  printf "Test with:\n";
  printf "  ghz --insecure --proto bench/go-comparison/echo.proto \\\n";
  printf "      --call echo.Echo/Echo -d '{\"message\":\"hello\"}' \\\n";
  printf "      -n 10000 -c 50 127.0.0.1:%d\n\n%!" port;

  (* Worker domain function *)
  let domain_worker id () =
    Eio_main.run @@ fun env ->
    let net = Eio.Stdenv.net env in
    Eio.Switch.run @@ fun sw ->
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true ~reuse_port:true net addr in

    printf "  Domain %d: Ready\n%!" id;

    while true do
      Eio.Net.accept_fork ~sw socket ~on_error:(fun exn ->
        printf "Domain %d error: %s\n%!" id (Printexc.to_string exn))
        (fun client_socket client_addr ->
          Eio.Switch.run @@ fun inner_sw ->
          H2_eio.Server.create_connection_handler
            ~request_handler:echo_handler
            ~error_handler
            ~sw:inner_sw
            client_addr
            client_socket)
    done
  in

  (* Spawn worker domains *)
  let workers = List.init (num_domains - 1) (fun i ->
    printf "  Spawning domain %d...\n%!" (i + 1);
    Domain.spawn (domain_worker (i + 1))
  ) in

  (* Main domain also serves *)
  let net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true ~reuse_port:true net addr in

  printf "  Domain 0: Ready (main)\n%!";
  printf "\nAll %d domains ready. Waiting for connections...\n%!" num_domains;

  (* This runs until Ctrl+C *)
  while true do
    Eio.Net.accept_fork ~sw socket ~on_error:(fun exn ->
      printf "Domain 0 error: %s\n%!" (Printexc.to_string exn))
      (fun client_socket client_addr ->
        Eio.Switch.run @@ fun inner_sw ->
        H2_eio.Server.create_connection_handler
          ~request_handler:echo_handler
          ~error_handler
          ~sw:inner_sw
          client_addr
          client_socket)
  done;

  (* Cleanup - won't reach here normally *)
  List.iter Domain.join workers

let () =
  let multi = ref false in
  let domains = ref 0 in
  Arg.parse [
    "--multi", Arg.Set multi, "Enable multi-domain mode";
    "--domains", Arg.Set_int domains, "Number of domains (0=auto)";
  ] (fun _ -> ()) "grpc-direct benchmark server";

  Eio_main.run @@ fun env ->
  if !multi then
    run_multi_domain ~domains:!domains env
  else
    run_single_domain env
