(** H2_lite Echo Server - Benchmarkable with ghz

    A minimal gRPC echo server using h2_lite for performance testing.
    Compatible with the echo.proto service definition.

    Usage:
      dune exec lib/grpc_eio/h2_lite/echo_server.exe -- [port]

    Benchmark:
      ghz --insecure --proto echo.proto --call echo.EchoService/Echo \
          -d '{"message":"hello"}' -c 50 -n 10000 localhost:50051
*)

open Eio.Std

(** Optimize socket for low-latency high-throughput gRPC.

    Sets TCP_NODELAY (disables Nagle's algorithm) and increases buffer sizes.
    grpc-go uses TCP_NODELAY by default. For request-response patterns,
    Nagle's algorithm adds latency by buffering small writes. Our echo response
    is already batched (HEADERS + DATA + TRAILERS in one syscall), so TCP_NODELAY
    should flush immediately instead of waiting for ACK.
*)
let optimize_socket (flow : _ Eio.Flow.two_way) =
  match Eio_unix.Resource.fd_opt (flow :> _ Eio.Resource.t) with
  | Some fd ->
    Eio_unix.Fd.use_exn "setsockopt" fd (fun unix_fd ->
      (* TCP_NODELAY: disable Nagle's algorithm for immediate sends *)
      Unix.setsockopt unix_fd Unix.TCP_NODELAY true;
      (* Increase socket buffer sizes for better throughput
         grpc-go uses 32KB, we use 256KB for batching *)
      Unix.setsockopt_int unix_fd Unix.SO_SNDBUF (256 * 1024);
      Unix.setsockopt_int unix_fd Unix.SO_RCVBUF (256 * 1024)
    )
  | None -> () (* Not a Unix socket, ignore *)

(** Tune GC for lower tail latency during benchmarks. *)
let tune_gc () =
  match Sys.getenv_opt "GRPC_EIO_GC_TUNE" with
  | Some ("0" | "false" | "off") -> ()
  | _ ->
    let gc = Gc.get () in
    let minor_heap_size = max gc.minor_heap_size 1_048_576 in
    let major_heap_increment = max gc.major_heap_increment 4_194_304 in
    let space_overhead = max gc.space_overhead 120 in
    Gc.set { gc with minor_heap_size; major_heap_increment; space_overhead }

(** Optional GC trace for p99 correlation (disabled by default). *)
let gc_alarm : Gc.alarm option ref = ref None
let outlier_threshold_ms : float option ref = ref None

let setup_gc_trace () =
  match Sys.getenv_opt "GRPC_EIO_GC_TRACE" with
  | Some ("1" | "true" | "on") ->
    let start_time = Unix.gettimeofday () in
    let last_major = ref 0 in
    gc_alarm := Some (Gc.create_alarm (fun () ->
      let st = Gc.quick_stat () in
      if st.Gc.major_collections > !last_major then begin
        last_major := st.Gc.major_collections;
        let elapsed = Unix.gettimeofday () -. start_time in
        traceln "GC major=%d minor=%d heap_words=%d live_words=%d time=%.3fs"
          st.Gc.major_collections st.Gc.minor_collections
          st.Gc.heap_words st.Gc.live_words elapsed
      end
    ))
  | _ -> ()

let setup_outlier_log () =
  match Sys.getenv_opt "GRPC_EIO_ECHO_OUTLIER_MS" with
  | Some value ->
    (try
       let threshold = float_of_string value in
       if threshold > 0.0 then outlier_threshold_ms := Some threshold
     with
     | _ -> ())
  | None -> ()

(** Stream multiplexer for concurrent streams *)
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
    next_server_stream_id = 2l;  (* Server uses even IDs *)
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

  let _active_count t =
    Hashtbl.length t.streams
end

(** Server connection handler (full HTTP/2 + HPACK) *)
let handle_connection_full flow _addr =
  (* Optimize socket for low-latency high-throughput (like grpc-go) *)
  optimize_socket flow;
  let conn = H2_lite.Connection.create flow in
  let outlier_ms = !outlier_threshold_ms in
  (* RFC 7541: Decoder for incoming headers (encoder not needed - using pre-encoded) *)
  let hpack_decoder = H2_lite.Hpack.create () in

  (* Flow control: track bytes received for batched WINDOW_UPDATE *)
  let bytes_consumed = ref 0 in

  try
    (* Server handshake *)
    H2_lite.Connection.server_handshake conn;

    (* RFC 7541: Set decoder's max size to match what we told the peer.
       We send SETTINGS(header_table_size=X), peer should limit encoder to X.
       Our decoder should expect at most X bytes in dynamic table. *)
    let local_header_table_size = conn.H2_lite.Connection.local_settings.header_table_size in
    H2_lite.Hpack.set_max_size hpack_decoder local_header_table_size;

    (* RFC 7540 §6.9.2: Increase connection-level window beyond default 65535
       Send WINDOW_UPDATE immediately to allow more data from client *)
    let target_conn_window = 16 * 1024 * 1024 in
    let conn_window_increase = Int32.of_int (target_conn_window - 65535) in
    H2_lite.Connection.send_window_update conn ~stream_id:0l ~increment:conn_window_increase;

    let mux = Multiplexer.create () in

    (* Main loop: read frames and handle them *)
    while not conn.closed do
      let frame = H2_lite.Connection.read_frame conn in
      let stream_id = frame.H2_lite.Frame.header.stream_id in

      match frame.H2_lite.Frame.header.frame_type with
      | H2_lite.Frame.Headers ->
        (* New request - create stream entry and decode headers *)
        let _entry = Multiplexer.get_or_create mux stream_id in
        let _headers = H2_lite.Hpack.decode hpack_decoder frame.payload in
        ()

      | H2_lite.Frame.Data ->
        (* Request body received *)
        let entry = Multiplexer.get_or_create mux stream_id in
        let data_len = Cstruct.length frame.payload in

        (* RFC 7540 §5.2: Batched flow control - update when threshold exceeded
           Send WINDOW_UPDATE for connection only, once per 32KB consumed.
           Note: Piggyback pattern was tested but hurt small message performance! *)
        bytes_consumed := !bytes_consumed + data_len;
        if !bytes_consumed > 32768 then begin
          let increment = Int32.of_int !bytes_consumed in
          H2_lite.Connection.send_window_update conn ~stream_id:0l ~increment;
          bytes_consumed := 0
        end;

        (* Skip empty DATA frames (e.g., END_STREAM only) *)
        if data_len < 5 then
          ()  (* gRPC header is 5 bytes minimum *)
        else begin
          (* Decode gRPC message - zero-copy slice of request body *)
          let request_body, _ = H2_lite.Grpc_message.decode frame.payload in

          (* Zero-allocation echo response path:
             Single function writes HEADERS + DATA + TRAILERS directly to buffer *)
          (match outlier_ms with
          | Some threshold ->
            let t0 = Unix.gettimeofday () in
            H2_lite.Connection.write_echo_response conn ~stream_id request_body;
            let elapsed_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
            if elapsed_ms >= threshold then
              traceln "Outlier: stream=%ld len=%d ms=%.3f"
                stream_id (Cstruct.length request_body) elapsed_ms
          | None ->
            H2_lite.Connection.write_echo_response conn ~stream_id request_body);

          (* Mark stream as done *)
          entry.state <- H2_lite.Stream.Closed;
          Multiplexer.remove mux stream_id
        end

      | H2_lite.Frame.Settings when H2_lite.Frame.Flags.is_set
          frame.H2_lite.Frame.header.flags H2_lite.Frame.Flags.ack ->
        (* Settings ACK - ignore *)
        ()

      | H2_lite.Frame.Settings ->
        (* Peer settings - apply header table size to decoder, then ACK *)
        let settings = H2_lite.Connection.parse_settings_payload frame.payload in
        List.iter (fun (id, value) ->
          if id = 1 then  (* SETTINGS_HEADER_TABLE_SIZE *)
            H2_lite.Hpack.set_max_size hpack_decoder (Int32.to_int value)
        ) settings;
        H2_lite.Connection.send_settings_ack conn

      | H2_lite.Frame.Ping when H2_lite.Frame.Flags.is_set
          frame.H2_lite.Frame.header.flags H2_lite.Frame.Flags.ack ->
        (* Ping ACK - ignore *)
        ()

      | H2_lite.Frame.Ping ->
        (* Ping request - respond *)
        H2_lite.Connection.send_ping conn ~ack:true frame.payload

      | H2_lite.Frame.WindowUpdate ->
        (* Window update - should apply to flow control *)
        ()

      | H2_lite.Frame.GoAway ->
        (* Peer is shutting down *)
        conn.goaway_received <- true

      | H2_lite.Frame.RstStream ->
        (* Stream cancelled *)
        Multiplexer.remove mux stream_id

      | _ ->
        (* Ignore unknown frames *)
        ()
    done
  with
  | End_of_file ->
    H2_lite.Connection.close conn
  | exn ->
    H2_lite.Connection.close conn;
    traceln "Connection error: %s" (Printexc.to_string exn)

(** Server connection handler (fast path for benchmarks). *)
let handle_connection_fast flow _addr =
  optimize_socket flow;
  let conn = H2_lite.Connection.create flow in
  let outlier_ms = !outlier_threshold_ms in
  let window_updates =
    match Sys.getenv_opt "GRPC_EIO_ECHO_WINDOW_UPDATES" with
    | Some ("0" | "false" | "off") -> false
    | _ -> true
  in
  let bytes_consumed = ref 0 in

  try
    H2_lite.Connection.server_handshake conn;

    let target_conn_window = 16 * 1024 * 1024 in
    let conn_window_increase = Int32.of_int (target_conn_window - 65535) in
    H2_lite.Connection.send_window_update conn ~stream_id:0l ~increment:conn_window_increase;

    while not conn.closed do
      let frame = H2_lite.Connection.read_frame conn in

      match frame.H2_lite.Frame.header.frame_type with
      | H2_lite.Frame.Headers ->
        ()

      | H2_lite.Frame.Data ->
        let stream_id = frame.H2_lite.Frame.header.stream_id in
        let data_len = Cstruct.length frame.payload in
        let window_increment =
          if window_updates then (
            bytes_consumed := !bytes_consumed + data_len;
            if !bytes_consumed > 32768 then (
              let inc = !bytes_consumed in
              bytes_consumed := 0;
              inc
            ) else
              0
          ) else
            0
        in

        if data_len >= 5 then begin
          let msg_len = Cstruct.BE.get_uint32 frame.payload 1 |> Int32.to_int in
          if msg_len > 0 && 5 + msg_len <= data_len then begin
            let request_body = Cstruct.sub frame.payload 5 msg_len in
            let write_response () =
              if window_updates then
                H2_lite.Connection.write_echo_response_with_window_update conn ~stream_id request_body ~window_increment
              else
                H2_lite.Connection.write_echo_response conn ~stream_id request_body
            in
            (match outlier_ms with
            | Some threshold ->
              let t0 = Unix.gettimeofday () in
              write_response ();
              let elapsed_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
              if elapsed_ms >= threshold then
                traceln "Outlier: stream=%ld len=%d ms=%.3f"
                  stream_id msg_len elapsed_ms
            | None ->
              write_response ())
          end else if window_updates && window_increment > 0 then
            H2_lite.Connection.send_window_update conn ~stream_id:0l
              ~increment:(Int32.of_int window_increment)
        end

      | H2_lite.Frame.Settings ->
        if not (H2_lite.Frame.Flags.is_set
            frame.H2_lite.Frame.header.flags H2_lite.Frame.Flags.ack) then
          H2_lite.Connection.send_settings_ack conn

      | H2_lite.Frame.Ping ->
        if not (H2_lite.Frame.Flags.is_set
            frame.H2_lite.Frame.header.flags H2_lite.Frame.Flags.ack) then
          H2_lite.Connection.send_ping conn ~ack:true frame.payload

      | H2_lite.Frame.WindowUpdate | H2_lite.Frame.GoAway
      | H2_lite.Frame.RstStream | _ ->
        ()
    done
  with
  | End_of_file ->
    H2_lite.Connection.close conn
  | exn ->
    H2_lite.Connection.close conn;
    traceln "Connection error: %s" (Printexc.to_string exn)

(** Main server entry point *)
let run_server ~env ~port =
  let net = Eio.Stdenv.net env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let use_fast =
    match Sys.getenv_opt "GRPC_EIO_ECHO_FAST" with
    | Some ("0" | "false" | "off") -> false
    | _ -> true
  in
  let handler =
    if use_fast then handle_connection_fast else handle_connection_full
  in

  Switch.run @@ fun sw ->
  let socket = Eio.Net.listen net ~sw ~backlog:1024 ~reuse_addr:true addr in

  traceln "H2_lite Echo Server listening on port %d" port;
  traceln "Echo mode: %s" (if use_fast then "fast" else "full");
  traceln "Benchmark with: ghz --insecure --proto echo.proto --call echo.EchoService/Echo -d '{\"message\":\"hello\"}' -c 50 -n 10000 localhost:%d" port;

  (* Pre-warm buffer pools *)
  H2_lite.Buffer_pool.prewarm ~count_per_class:64;

  (* Accept loop *)
  while true do
    Eio.Net.accept_fork socket ~sw ~on_error:(fun exn ->
      traceln "Accept error: %s" (Printexc.to_string exn)
    ) handler
  done

let () =
  let port =
    if Array.length Sys.argv > 1 then
      int_of_string Sys.argv.(1)
    else
      50051
  in

  tune_gc ();
  setup_gc_trace ();
  setup_outlier_log ();
  Eio_main.run @@ fun env ->
  traceln "";
  traceln "╔═══════════════════════════════════════════════════════╗";
  traceln "║       H2_lite Echo Server (RFC 7540 + RFC 7541)       ║";
  traceln "╚═══════════════════════════════════════════════════════╝";
  traceln "";
  run_server ~env ~port
