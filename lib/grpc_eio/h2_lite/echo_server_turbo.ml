(** H2_lite Turbo Echo Server - Maximum Performance

    Stripped down echo server for benchmarking.
    Removes ALL unnecessary overhead:
    - No HPACK decoding (we don't need headers for echo)
    - No stream state management (echo is stateless)
    - No multiplexer (handle frames inline)
    - Minimal frame type dispatch

    Usage:
      dune exec lib/grpc_eio/h2_lite/echo_server_turbo.exe -- [port]
*)

open Eio.Std

(** Optimize socket for low-latency *)
let optimize_socket (flow : _ Eio.Flow.two_way) =
  match Eio_unix.Resource.fd_opt (flow :> _ Eio.Resource.t) with
  | Some fd ->
    Eio_unix.Fd.use_exn "setsockopt" fd (fun unix_fd ->
      Unix.setsockopt unix_fd Unix.TCP_NODELAY true;
      Unix.setsockopt_int unix_fd Unix.SO_SNDBUF (256 * 1024);
      Unix.setsockopt_int unix_fd Unix.SO_RCVBUF (256 * 1024))
  | None -> ()
;;

(** Turbo connection handler - minimal overhead *)
let handle_connection flow _addr =
  optimize_socket flow;
  let conn = H2_lite.Connection.create flow in
  (* Flow control: track bytes received *)
  let bytes_consumed = ref 0 in
  try
    (* Server handshake *)
    H2_lite.Connection.server_handshake conn;
    (* Increase connection window to 16MB *)
    let target_conn_window = 16 * 1024 * 1024 in
    let conn_window_increase = Int32.of_int (target_conn_window - 65535) in
    H2_lite.Connection.send_window_update
      conn
      ~stream_id:0l
      ~increment:conn_window_increase;
    (* Main loop: ultra-tight frame processing *)
    while not conn.closed do
      let frame = H2_lite.Connection.read_frame conn in
      (* Fast path: only handle what we need *)
      match frame.H2_lite.Frame.header.frame_type with
      | H2_lite.Frame.Headers ->
        (* Just acknowledge - no decoding needed! *)
        ()
      | H2_lite.Frame.Data ->
        let stream_id = frame.H2_lite.Frame.header.stream_id in
        let data_len = Cstruct.length frame.payload in
        (* Batched WINDOW_UPDATE *)
        bytes_consumed := !bytes_consumed + data_len;
        if !bytes_consumed > 131072
        then (
          H2_lite.Connection.send_window_update
            conn
            ~stream_id:0l
            ~increment:(Int32.of_int !bytes_consumed);
          bytes_consumed := 0);
        (* Echo if we have payload *)
        if data_len >= 5
        then (
          (* Direct gRPC decode - skip 5-byte header *)
          let msg_len = Cstruct.BE.get_uint32 frame.payload 1 |> Int32.to_int in
          if msg_len > 0 && 5 + msg_len <= data_len
          then (
            let request_body = Cstruct.sub frame.payload 5 msg_len in
            H2_lite.Connection.write_echo_response conn ~stream_id request_body))
      | H2_lite.Frame.Settings ->
        (* Only ACK non-ACK settings *)
        if
          not
            (H2_lite.Frame.Flags.is_set
               frame.H2_lite.Frame.header.flags
               H2_lite.Frame.Flags.ack)
        then H2_lite.Connection.send_settings_ack conn
      | H2_lite.Frame.Ping ->
        if
          not
            (H2_lite.Frame.Flags.is_set
               frame.H2_lite.Frame.header.flags
               H2_lite.Frame.Flags.ack)
        then H2_lite.Connection.send_ping conn ~ack:true frame.payload
      | H2_lite.Frame.WindowUpdate | H2_lite.Frame.GoAway | H2_lite.Frame.RstStream | _ ->
        (* Ignore everything else *)
        ()
    done
  with
  | End_of_file -> H2_lite.Connection.close conn
  | exn ->
    H2_lite.Connection.close conn;
    traceln "Connection error: %s" (Printexc.to_string exn)
;;

(** Main entry point *)
let run_server ~env ~port =
  let net = Eio.Stdenv.net env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  Switch.run
  @@ fun sw ->
  let socket = Eio.Net.listen net ~sw ~backlog:1024 ~reuse_addr:true addr in
  traceln "H2_lite TURBO Echo Server listening on port %d" port;
  traceln "Optimizations: No HPACK decode, No state tracking, Inline gRPC decode";
  (* Pre-warm buffer pools *)
  H2_lite.Buffer_pool.prewarm ~count_per_class:16;
  (* Accept loop *)
  while true do
    Eio.Net.accept_fork
      socket
      ~sw
      ~on_error:(fun exn -> traceln "Accept error: %s" (Printexc.to_string exn))
      handle_connection
  done
;;

let () =
  let port = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 50051 in
  Eio_main.run
  @@ fun env ->
  traceln "";
  traceln "╔═══════════════════════════════════════════════════════╗";
  traceln "║   H2_lite TURBO Echo Server (Zero Overhead)           ║";
  traceln "╚═══════════════════════════════════════════════════════╝";
  traceln "";
  run_server ~env ~port
;;
