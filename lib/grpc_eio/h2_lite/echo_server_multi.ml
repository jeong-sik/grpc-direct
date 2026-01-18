(** H2_lite Multi-Domain Echo Server

    Uses SO_REUSEPORT for kernel-level load balancing across multiple OCaml domains.
    Each domain has its own event loop and GC, enabling true parallel processing.

    Expected performance improvement: 2-3x over single-domain.

    Usage:
      dune exec lib/grpc_eio/h2_lite/echo_server_multi.exe -- [port] [num_domains]

    Benchmark:
      ghz --insecure --proto echo.proto --call echo.EchoService/Echo \
          -d '{"message":"hello"}' -c 50 -n 50000 localhost:50051
*)

open Eio.Std

(** Stream multiplexer for concurrent streams (same as echo_server.ml) *)
module Multiplexer = struct
  type stream_entry = {
    mutable state : H2_lite.Stream.state;
    mutable pending_data : Cstruct.t list;
    mutable window_size : int;
  }

  type t = {
    streams : (int32, stream_entry) Hashtbl.t;
    mutable next_server_stream_id : int32;
  }

  let create () = {
    streams = Hashtbl.create 64;
    next_server_stream_id = 2l;
  }

  let get_or_create t stream_id =
    match Hashtbl.find_opt t.streams stream_id with
    | Some entry -> entry
    | None ->
      let entry = {
        state = H2_lite.Stream.Open;
        pending_data = [];
        window_size = 65535;
      } in
      Hashtbl.add t.streams stream_id entry;
      entry

  let remove t stream_id =
    Hashtbl.remove t.streams stream_id
end

(** Connection handler - processes one HTTP/2 connection *)
let handle_connection flow _addr =
  let conn = H2_lite.Connection.create flow in
  let hpack_decoder = H2_lite.Hpack.create () in
  let hpack_encoder = H2_lite.Hpack.create () in
  let bytes_consumed = ref 0 in

  try
    H2_lite.Connection.server_handshake conn;

    (* Large initial window for high throughput *)
    let conn_window_increase = Int32.of_int (1048576 - 65535) in
    H2_lite.Connection.send_window_update conn ~stream_id:0l ~increment:conn_window_increase;

    let mux = Multiplexer.create () in

    while not conn.closed do
      let frame = H2_lite.Connection.read_frame conn in
      let stream_id = frame.H2_lite.Frame.header.stream_id in

      match frame.H2_lite.Frame.header.frame_type with
      | H2_lite.Frame.Headers ->
        let _entry = Multiplexer.get_or_create mux stream_id in
        let _headers = H2_lite.Hpack.decode hpack_decoder frame.payload in
        ()

      | H2_lite.Frame.Data ->
        let entry = Multiplexer.get_or_create mux stream_id in
        let data_len = Cstruct.length frame.payload in

        bytes_consumed := !bytes_consumed + data_len;
        if !bytes_consumed > 32768 then begin
          let increment = Int32.of_int !bytes_consumed in
          H2_lite.Connection.send_window_update conn ~stream_id:0l ~increment;
          bytes_consumed := 0
        end;

        if data_len < 5 then ()
        else begin
          let request_body, _ = H2_lite.Grpc_message.decode frame.payload in
          let response_body = request_body in

          let resp_headers = H2_lite.Hpack.grpc_response_headers () in
          let encoded_headers = H2_lite.Hpack.encode hpack_encoder resp_headers in
          let headers_frame = H2_lite.Frame.make_headers
            ~stream_id ~end_stream:false ~end_headers:true encoded_headers
          in

          let encoded_body = H2_lite.Grpc_message.encode response_body in
          let data_frame = H2_lite.Frame.make_data
            ~stream_id ~end_stream:false encoded_body
          in

          let trailers = H2_lite.Hpack.grpc_trailers 0 in
          let encoded_trailers = H2_lite.Hpack.encode hpack_encoder trailers in
          let trailers_frame = H2_lite.Frame.make_headers
            ~stream_id ~end_stream:true ~end_headers:true encoded_trailers
          in

          H2_lite.Connection.write_frames conn [headers_frame; data_frame; trailers_frame];

          entry.state <- H2_lite.Stream.Closed;
          Multiplexer.remove mux stream_id
        end

      | H2_lite.Frame.Settings when H2_lite.Frame.Flags.is_set
          frame.H2_lite.Frame.header.flags H2_lite.Frame.Flags.ack -> ()
      | H2_lite.Frame.Settings ->
        H2_lite.Connection.send_settings_ack conn
      | H2_lite.Frame.Ping when H2_lite.Frame.Flags.is_set
          frame.H2_lite.Frame.header.flags H2_lite.Frame.Flags.ack -> ()
      | H2_lite.Frame.Ping ->
        H2_lite.Connection.send_ping conn ~ack:true frame.payload
      | H2_lite.Frame.WindowUpdate -> ()
      | H2_lite.Frame.GoAway ->
        conn.goaway_received <- true
      | H2_lite.Frame.RstStream ->
        Multiplexer.remove mux stream_id
      | _ -> ()
    done
  with
  | End_of_file -> H2_lite.Connection.close conn
  | _exn -> H2_lite.Connection.close conn

(** Global shutdown signal *)
let global_shutdown = Atomic.make false

(** Domain worker function *)
let domain_worker ~port ~domain_id () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in

  Switch.run @@ fun sw ->
  (* SO_REUSEPORT allows multiple sockets on same port *)
  let socket = Eio.Net.listen net ~sw ~backlog:1024 ~reuse_addr:true ~reuse_port:true addr in

  (* Pre-warm buffer pools for this domain *)
  H2_lite.Buffer_pool.prewarm ~count_per_class:16;

  traceln "  Domain %d: Listening on port %d" domain_id port;

  while not (Atomic.get global_shutdown) do
    Eio.Net.accept_fork socket ~sw ~on_error:(fun _exn -> ())
      handle_connection
  done;
  traceln "  Domain %d: Stopped" domain_id

(** Multi-domain server entry point *)
let run_multi ~port ~num_domains =
  Printf.printf "╔═══════════════════════════════════════════════════════╗\n";
  Printf.printf "║  H2_lite Multi-Domain Echo Server (SO_REUSEPORT)      ║\n";
  Printf.printf "╚═══════════════════════════════════════════════════════╝\n\n";
  Printf.printf "Configuration:\n";
  Printf.printf "  Port:     %d\n" port;
  Printf.printf "  Domains:  %d\n" num_domains;
  Printf.printf "  CPU cores: %d available\n\n" (Domain.recommended_domain_count ());

  (* Spawn worker domains (1 to N-1) *)
  let worker_domains =
    List.init (num_domains - 1) (fun i ->
      let domain_id = i + 1 in
      traceln "  Spawning domain %d..." domain_id;
      Domain.spawn (domain_worker ~port ~domain_id)
    )
  in

  (* Main domain (domain 0) also serves *)
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in

  Switch.run @@ fun sw ->
  let socket = Eio.Net.listen net ~sw ~backlog:1024 ~reuse_addr:true ~reuse_port:true addr in
  H2_lite.Buffer_pool.prewarm ~count_per_class:16;

  traceln "  Domain 0: Listening on port %d (main)" port;
  Printf.printf "\nBenchmark with:\n";
  Printf.printf "  ghz --insecure --proto echo.proto --call echo.EchoService/Echo \\\n";
  Printf.printf "      -d '{\"message\":\"hello\"}' -c 50 -n 50000 localhost:%d\n\n" port;

  while not (Atomic.get global_shutdown) do
    Eio.Net.accept_fork socket ~sw ~on_error:(fun _exn -> ())
      handle_connection
  done;

  (* Wait for worker domains *)
  List.iter Domain.join worker_domains;
  traceln "All domains stopped"

let () =
  let port =
    if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 50051
  in
  let num_domains =
    if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2)
    else min 4 (Domain.recommended_domain_count ())  (* Default: 4 or max available *)
  in
  run_multi ~port ~num_domains
