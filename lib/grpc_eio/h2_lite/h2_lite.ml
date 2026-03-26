(** H2_lite - Minimal HTTP/2 for gRPC (RFC 7540 compliant)

    A gRPC-optimized HTTP/2 implementation based on:
    - RFC 7540: HTTP/2 Protocol
    - RFC 7541: HPACK Header Compression
    - gRPC over HTTP/2 specification

    Key optimizations:
    - Proper HPACK with dynamic table (not static-only)
    - Stream state machine per RFC 7540 §5.1
    - Flow control per RFC 7540 §5.2
    - Eio-native with fiber multiplexing

    Usage:
    {[
      (* Client *)
      Eio.Switch.run @@ fun sw ->
      let conn = H2_lite.connect ~sw ~env target in
      let stream = H2_lite.open_stream conn in
      H2_lite.send_request stream ~headers ~body;
      let response = H2_lite.recv_response stream in
      ...

      (* Server *)
      H2_lite.serve ~sw ~env ~port handler
    ]}
*)

(** Re-export RFC-based submodules *)
module Buffer_pool = Buffer_pool

module Frame = Frame
module Hpack = Hpack (* RFC 7541 *)
module Stream = Stream (* RFC 7540 §5.1 *)
module Flow_control = Flow_control (* RFC 7540 §5.2 *)
module Grpc_message = Grpc_message (* gRPC framing *)
module Connection = Connection

(** Stream handle with proper state machine *)
type stream =
  { conn : Connection.t
  ; id : int32
  ; stream_state : Stream.t (* RFC 7540 state machine *)
  ; hpack_encoder : Hpack.t (* Per-connection HPACK encoder *)
  ; hpack_decoder : Hpack.t (* Per-connection HPACK decoder *)
  ; flow_control : Flow_control.t (* Per-connection flow control *)
  }

(** PUSH_PROMISE response payload (RFC 7540 §6.6) *)
type push_response =
  { promised_stream_id : int32
  ; request_headers : (string * string) list
  ; response_headers : (string * string) list
  ; response_body : Cstruct.t
  ; trailers : (string * string) list
  }

(** Create a new stream on connection *)
let open_stream
      ~is_client
      ~hpack_encoder
      ~hpack_decoder
      ~flow_control
      (conn : Connection.t)
  : stream
  =
  let id = Connection.next_stream_id conn ~is_client in
  { conn
  ; id
  ; stream_state = Stream.create id
  ; hpack_encoder
  ; hpack_decoder
  ; flow_control
  }
;;

(** Send DATA frame on stream with proper state transition *)
let send_data stream ~end_stream (data : Cstruct.t) =
  let data_len = Cstruct.length data in
  if not (Flow_control.can_send stream.flow_control stream.id data_len)
  then failwith "FLOW_CONTROL_ERROR: send window exhausted";
  Flow_control.consume stream.flow_control stream.id data_len;
  (* Transition stream state *)
  Stream.transition_send stream.stream_state `Data ~end_stream;
  (* Send frame *)
  let frame = Frame.make_data ~stream_id:stream.id ~end_stream data in
  Connection.write_frame stream.conn frame
;;

(** Send PRIORITY frame for a stream *)
let send_priority stream (priority : Frame.priority_info) =
  Stream.set_priority stream.stream_state priority;
  Connection.update_priority stream.conn ~stream_id:stream.id priority;
  let frame = Frame.make_priority ~stream_id:stream.id priority in
  Connection.write_frame stream.conn frame
;;

(** Send HEADERS frame(s) on stream using HPACK encoding. *)
let send_headers ?priority stream ~end_stream (headers : (string * string) list) =
  (* Transition stream state *)
  Stream.transition_send stream.stream_state `Headers ~end_stream;
  let max_header_list_size = stream.conn.Connection.peer_settings.max_header_list_size in
  if max_header_list_size >= 0
  then (
    let size = Hpack.header_list_size headers in
    if size > max_header_list_size
    then invalid_arg "Header list size exceeds peer SETTINGS_MAX_HEADER_LIST_SIZE");
  (* HPACK encode headers *)
  let encoded = Hpack.encode stream.hpack_encoder headers in
  (* Fragment if needed per peer SETTINGS_MAX_FRAME_SIZE *)
  let frames =
    Frame.make_headers_fragmented
      ~stream_id:stream.id
      ~end_stream
      ?priority
      ~max_frame_size:(Connection.peer_max_frame_size stream.conn)
      encoded
  in
  match frames with
  | [] -> ()
  | [ frame ] -> Connection.write_frame stream.conn frame
  | _ -> Connection.write_frames stream.conn frames
;;

(** Send PUSH_PROMISE on stream and return promised stream handle *)
let send_push_promise stream ~(headers : (string * string) list) : stream =
  if not stream.conn.Connection.local_settings.enable_push
  then invalid_arg "PUSH_PROMISE disabled by local settings";
  let promised_stream_id = Connection.next_stream_id stream.conn ~is_client:false in
  let encoded = Hpack.encode stream.hpack_encoder headers in
  let frames =
    Frame.make_push_promise_fragmented
      ~stream_id:stream.id
      ~promised_stream_id
      ~max_frame_size:(Connection.peer_max_frame_size stream.conn)
      encoded
  in
  Connection.write_frames stream.conn frames;
  { conn = stream.conn
  ; id = promised_stream_id
  ; stream_state = Stream.create_reserved_local promised_stream_id
  ; hpack_encoder = stream.hpack_encoder
  ; hpack_decoder = stream.hpack_decoder
  ; flow_control = stream.flow_control
  }
;;

(** Handle connection-level frames *)
let handle_connection_frame conn flow_control hpack_encoder (frame : Frame.t) =
  match frame.Frame.header.frame_type with
  | Frame.Settings when Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.ack ->
    () (* Settings ACK *)
  | Frame.Settings ->
    (try
       let settings = Connection.parse_settings_payload frame.Frame.payload in
       Connection.apply_peer_settings conn settings;
       Flow_control.update_initial_window_size
         flow_control
         conn.Connection.peer_settings.initial_window_size;
       Hpack.set_max_size hpack_encoder conn.Connection.peer_settings.header_table_size;
       Connection.send_settings_ack conn
     with
     | Invalid_argument msg | Failure msg ->
       raise (Connection.Connection_error (Frame.Error_code.protocol_error, msg)))
  | Frame.Ping when Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.ack ->
    () (* Ping ACK *)
  | Frame.Ping -> Connection.send_ping conn ~ack:true frame.Frame.payload
  | Frame.WindowUpdate ->
    if Cstruct.length frame.Frame.payload <> 4
    then
      raise
        (Connection.Connection_error
           (Frame.Error_code.protocol_error, "Invalid WINDOW_UPDATE payload"));
    let raw = Cstruct.BE.get_uint32 frame.Frame.payload 0 in
    let increment = Int32.logand raw 0x7FFFFFFFl |> Int32.to_int in
    if increment = 0
    then
      if frame.header.stream_id = 0l
      then
        raise
          (Connection.Connection_error
             (Frame.Error_code.protocol_error, "WINDOW_UPDATE increment 0"))
      else (
        let rst =
          Frame.make_rst_stream
            ~stream_id:frame.header.stream_id
            ~error_code:Frame.Error_code.flow_control_error
        in
        Connection.write_frame conn rst;
        Flow_control.remove_stream flow_control frame.header.stream_id)
    else Flow_control.update flow_control frame.header.stream_id increment
  | Frame.GoAway -> conn.Connection.goaway_received <- true
  | _ -> ()
;;

(** Receive frame for stream (filters by stream ID) *)
let rec recv_frame ?on_push stream : Frame.t =
  let decode_headers_for_stream stream frame =
    let headers = Hpack.decode stream.hpack_decoder frame.Frame.payload in
    let max_header_list_size =
      stream.conn.Connection.local_settings.max_header_list_size
    in
    if max_header_list_size >= 0
    then (
      let size = Hpack.header_list_size headers in
      if size > max_header_list_size
      then (
        let rst =
          Frame.make_rst_stream
            ~stream_id:stream.id
            ~error_code:Frame.Error_code.protocol_error
        in
        Connection.write_frame stream.conn rst;
        Flow_control.remove_stream stream.flow_control stream.id;
        failwith "Header list size exceeds SETTINGS_MAX_HEADER_LIST_SIZE"));
    headers
  in
  let apply_priority prio =
    try
      Stream.set_priority stream.stream_state prio;
      Connection.update_priority stream.conn ~stream_id:stream.id prio
    with
    | Stream.Stream_error (Stream.ProtocolError msg) ->
      let rst =
        Frame.make_rst_stream
          ~stream_id:stream.id
          ~error_code:Frame.Error_code.protocol_error
      in
      Connection.write_frame stream.conn rst;
      Flow_control.remove_stream stream.flow_control stream.id;
      failwith msg
  in
  let handle_window_update frame =
    if Cstruct.length frame.Frame.payload <> 4
    then failwith "Invalid WINDOW_UPDATE payload";
    let raw = Cstruct.BE.get_uint32 frame.Frame.payload 0 in
    let increment = Int32.logand raw 0x7FFFFFFFl |> Int32.to_int in
    if increment = 0
    then (
      let rst =
        Frame.make_rst_stream
          ~stream_id:frame.header.stream_id
          ~error_code:Frame.Error_code.flow_control_error
      in
      Connection.write_frame stream.conn rst;
      Flow_control.remove_stream stream.flow_control frame.header.stream_id)
    else Flow_control.update stream.flow_control frame.header.stream_id increment
  in
  let handle_push_promise info =
    let promised_id =
      match info.Connection.promised_stream_id with
      | Some id -> id
      | None -> failwith "Missing promised stream id"
    in
    if not stream.conn.Connection.local_settings.enable_push
    then (
      Connection.send_goaway
        stream.conn
        ~last_stream_id:stream.conn.Connection.last_stream_id
        ~error_code:Frame.Error_code.protocol_error
        ~debug_data:"PUSH_PROMISE disabled";
      failwith "PUSH_PROMISE disabled");
    let request_headers = Hpack.decode stream.hpack_decoder info.header_block in
    match on_push with
    | None ->
      let rst =
        Frame.make_rst_stream ~stream_id:promised_id ~error_code:Frame.Error_code.cancel
      in
      Connection.write_frame stream.conn rst;
      Flow_control.remove_stream stream.flow_control promised_id
    | Some handler ->
      let promised_stream =
        { conn = stream.conn
        ; id = promised_id
        ; stream_state = Stream.create_reserved_remote promised_id
        ; hpack_encoder = stream.hpack_encoder
        ; hpack_decoder = stream.hpack_decoder
        ; flow_control = stream.flow_control
        }
      in
      let response_headers = ref [] in
      let trailers = ref [] in
      let response_buffer = Buffer.create 4096 in
      let rec read_response () =
        let frame = recv_frame promised_stream in
        let end_stream = Frame.Flags.is_set frame.header.flags Frame.Flags.end_stream in
        (match frame.header.frame_type with
         | Frame.Headers ->
           let headers = decode_headers_for_stream promised_stream frame in
           if !response_headers = []
           then response_headers := headers
           else trailers := headers
         | Frame.Data ->
           Buffer.add_string response_buffer (Cstruct.to_string frame.Frame.payload)
         | Frame.RstStream -> failwith "Received RST_STREAM on pushed stream"
         | _ -> ());
        if not end_stream then read_response ()
      in
      read_response ();
      handler
        { promised_stream_id = promised_id
        ; request_headers
        ; response_headers = !response_headers
        ; response_body = Cstruct.of_string (Buffer.contents response_buffer)
        ; trailers = !trailers
        }
  in
  let rec loop () =
    let frame = Connection.read_frame stream.conn in
    match frame.Frame.header.frame_type with
    | Frame.PushPromise ->
      let info = Connection.read_header_block ~first_frame:frame stream.conn in
      handle_push_promise info;
      loop ()
    | Frame.Priority when frame.Frame.header.stream_id = stream.id ->
      let prio, _ = Frame.parse_priority frame.Frame.payload ~offset:0 in
      apply_priority prio;
      loop ()
    | Frame.WindowUpdate when frame.Frame.header.stream_id = stream.id ->
      handle_window_update frame;
      loop ()
    | _ ->
      if frame.Frame.header.stream_id = stream.id
      then (
        let frame =
          match frame.header.frame_type with
          | Frame.Headers ->
            let info = Connection.read_header_block ~first_frame:frame stream.conn in
            (match info.priority with
             | Some prio -> apply_priority prio
             | None -> ());
            let flags =
              frame.header.flags
              lor Frame.Flags.end_headers
              land lnot (Frame.Flags.priority lor Frame.Flags.padded)
            in
            let header =
              { frame.header with length = Cstruct.length info.header_block; flags }
            in
            Frame.{ header; payload = info.header_block }
          | _ -> frame
        in
        (* Transition state based on received frame *)
        let end_stream =
          Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.end_stream
        in
        let frame_type =
          match frame.header.frame_type with
          | Frame.Data -> `Data
          | Frame.Headers -> `Headers
          | Frame.RstStream -> `RstStream
          | _ -> `Data (* Treat others as data for state machine *)
        in
        Stream.transition_recv stream.stream_state frame_type ~end_stream;
        (match frame.header.frame_type with
         | Frame.Data ->
           let updates =
             Flow_control.consume_recv
               stream.flow_control
               stream.id
               (Cstruct.length frame.Frame.payload)
           in
           if updates <> []
           then (
             let update_frames =
               List.map
                 (fun (id, inc) ->
                    Frame.make_window_update ~stream_id:id ~increment:(Int32.of_int inc))
                 updates
             in
             Connection.write_frames stream.conn update_frames)
         | Frame.RstStream -> Flow_control.remove_stream stream.flow_control stream.id
         | _ -> ());
        frame)
      else if frame.Frame.header.stream_id = 0l
      then (
        handle_connection_frame stream.conn stream.flow_control stream.hpack_encoder frame;
        loop ())
      else (
        (match frame.header.frame_type with
         | Frame.Headers ->
           let info = Connection.read_header_block ~first_frame:frame stream.conn in
           (match info.priority with
            | Some prio ->
              Connection.update_priority stream.conn ~stream_id:info.stream_id prio
            | None -> ())
         | Frame.Priority ->
           let prio, _ = Frame.parse_priority frame.Frame.payload ~offset:0 in
           Connection.update_priority stream.conn ~stream_id:frame.header.stream_id prio
         | Frame.WindowUpdate -> handle_window_update frame
         | _ -> ());
        loop () (* Different stream, skip for now *))
  in
  loop ()
;;

(** Decode received HEADERS frame using HPACK *)
let decode_headers stream (frame : Frame.t) : (string * string) list =
  let headers = Hpack.decode stream.hpack_decoder frame.Frame.payload in
  let max_header_list_size = stream.conn.Connection.local_settings.max_header_list_size in
  if max_header_list_size >= 0
  then (
    let size = Hpack.header_list_size headers in
    if size > max_header_list_size
    then (
      let rst =
        Frame.make_rst_stream
          ~stream_id:stream.id
          ~error_code:Frame.Error_code.protocol_error
      in
      Connection.write_frame stream.conn rst;
      Flow_control.remove_stream stream.flow_control stream.id;
      failwith "Header list size exceeds SETTINGS_MAX_HEADER_LIST_SIZE"));
  headers
;;

(** Percent-decode grpc-message (RFC 3986) *)
let percent_decode s =
  let buf = Buffer.create (String.length s) in
  let len = String.length s in
  let rec loop i =
    if i >= len
    then ()
    else (
      match s.[i] with
      | '%' when i + 2 < len ->
        let hex = String.sub s (i + 1) 2 in
        (match int_of_string_opt ("0x" ^ hex) with
         | Some v ->
           Buffer.add_char buf (Char.chr v);
           loop (i + 3)
         | None ->
           Buffer.add_char buf s.[i];
           loop (i + 1))
      | c ->
        Buffer.add_char buf c;
        loop (i + 1))
  in
  loop 0;
  Buffer.contents buf
;;

(** High-level gRPC client API *)
module Client = struct
  type t =
    { conn : Connection.t
    ; authority : string
    ; scheme : string
    ; hpack_encoder : Hpack.t (* Shared HPACK encoder for connection *)
    ; hpack_decoder : Hpack.t (* Shared HPACK decoder for connection *)
    ; flow_control : Flow_control.t (* Shared flow control for connection *)
    ; on_push : (push_response -> unit) option
    }

  (** Connect to gRPC server *)
  let connect
        ?(enable_push = false)
        ?(priority_scheduling = true)
        ?on_push
        ~sw
        ~env
        ~host
        ~port
        ()
    : t
    =
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    let net = Eio.Stdenv.net env in
    let flow = Eio.Net.connect ~sw net addr in
    let settings =
      if enable_push
      then { Connection.grpc_settings with enable_push = true }
      else Connection.grpc_settings
    in
    let conn = Connection.create ~settings ~priority_scheduling flow in
    if priority_scheduling then Connection.start_priority_writer ~sw conn;
    Connection.client_handshake conn;
    let flow_control = Flow_control.create () in
    Flow_control.update_initial_window_size
      flow_control
      conn.Connection.peer_settings.initial_window_size;
    Flow_control.update_recv_initial_window_size
      flow_control
      conn.Connection.local_settings.initial_window_size;
    let hpack_encoder = Hpack.create () in
    let hpack_decoder = Hpack.create () in
    Hpack.set_max_size hpack_encoder conn.Connection.peer_settings.header_table_size;
    { conn
    ; authority = Printf.sprintf "%s:%d" host port
    ; scheme = "http"
    ; hpack_encoder
    ; hpack_decoder
    ; flow_control
    ; on_push
    }
  ;;

  (** Make unary gRPC call *)
  let call_unary (t : t) ~service ~method_ ~request : Cstruct.t =
    let stream =
      open_stream
        ~is_client:true
        ~hpack_encoder:t.hpack_encoder
        ~hpack_decoder:t.hpack_decoder
        ~flow_control:t.flow_control
        t.conn
    in
    let path = Printf.sprintf "/%s/%s" service method_ in
    (* gRPC request headers using proper HPACK *)
    let headers =
      [ ":method", "POST"
      ; ":scheme", t.scheme
      ; ":path", path
      ; ":authority", t.authority
      ; "content-type", "application/grpc+proto"
      ; "te", "trailers"
      ]
    in
    (* Send headers *)
    send_headers stream ~end_stream:false headers;
    (* Send request body *)
    let body = Grpc_message.encode request in
    send_data stream ~end_stream:true body;
    let response_buffer = Buffer.create 4096 in
    let status_code = ref None in
    let status_message = ref None in
    let record_status headers =
      match List.assoc_opt "grpc-status" headers with
      | Some s -> status_code := Some s
      | None ->
        ();
        (match List.assoc_opt "grpc-message" headers with
         | Some m -> status_message := Some (percent_decode m)
         | None -> ())
    in
    let rec read_response () =
      let frame = recv_frame ?on_push:t.on_push stream in
      let end_stream = Frame.Flags.is_set frame.header.flags Frame.Flags.end_stream in
      (match frame.header.frame_type with
       | Frame.Headers ->
         let headers = decode_headers stream frame in
         record_status headers
       | Frame.Data ->
         Buffer.add_string response_buffer (Cstruct.to_string frame.Frame.payload)
       | Frame.RstStream -> failwith "Received RST_STREAM from server"
       | _ -> ());
      if end_stream then () else read_response ()
    in
    read_response ();
    let status =
      match !status_code with
      | Some s -> int_of_string_opt s
      | None -> None
    in
    match status with
    | Some 0 ->
      let resp_body, _ =
        Grpc_message.decode (Cstruct.of_string (Buffer.contents response_buffer))
      in
      resp_body
    | Some code ->
      let msg = Option.value ~default:"Unknown error" !status_message in
      failwith (Printf.sprintf "gRPC error: %d (%s)" code msg)
    | None -> failwith "Missing grpc-status in response"
  ;;

  (** Close client connection *)
  let close (t : t) = Connection.close t.conn
end

(** High-level gRPC server API *)
module Server = struct
  type handler = stream -> Cstruct.t -> Cstruct.t

  (** Start gRPC server *)
  let serve
        ?(enable_push = false)
        ?(priority_scheduling = true)
        ~sw
        ~env
        ~port
        (handler : handler)
    =
    let net = Eio.Stdenv.net env in
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    let socket = Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true addr in
    let handle_connection flow _addr =
      let settings =
        if enable_push
        then { Connection.grpc_settings with enable_push = true }
        else Connection.grpc_settings
      in
      let conn = Connection.create ~settings ~priority_scheduling flow in
      if priority_scheduling then Connection.start_priority_writer ~sw conn;
      let hpack_decoder = Hpack.create () in
      (* Per-connection HPACK *)
      let hpack_encoder = Hpack.create () in
      let flow_control = Flow_control.create () in
      try
        Connection.server_handshake conn;
        Flow_control.update_initial_window_size
          flow_control
          conn.Connection.peer_settings.initial_window_size;
        Flow_control.update_recv_initial_window_size
          flow_control
          conn.Connection.local_settings.initial_window_size;
        Hpack.set_max_size hpack_encoder conn.Connection.peer_settings.header_table_size;
        while not conn.closed do
          let frame = Connection.read_frame conn in
          match frame.header.frame_type with
          | Frame.Headers ->
            (* New request *)
            let info = Connection.read_header_block ~first_frame:frame conn in
            let stream =
              { conn
              ; id = info.stream_id
              ; stream_state = Stream.create info.stream_id
              ; hpack_encoder
              ; hpack_decoder
              ; flow_control
              }
            in
            (* Transition stream state for received HEADERS *)
            let headers_end_stream =
              Frame.Flags.is_set frame.header.flags Frame.Flags.end_stream
            in
            Stream.transition_recv
              stream.stream_state
              `Headers
              ~end_stream:headers_end_stream;
            (match info.priority with
             | Some prio -> Connection.update_priority conn ~stream_id:info.stream_id prio
             | None -> ());
            (* Decode request headers *)
            let headers = Hpack.decode hpack_decoder info.header_block in
            let max_header_list_size =
              conn.Connection.local_settings.max_header_list_size
            in
            let headers_ok =
              if max_header_list_size >= 0
              then (
                let size = Hpack.header_list_size headers in
                size <= max_header_list_size)
              else true
            in
            if not headers_ok
            then (
              let rst =
                Frame.make_rst_stream
                  ~stream_id:info.stream_id
                  ~error_code:Frame.Error_code.protocol_error
              in
              Connection.write_frame conn rst;
              Flow_control.remove_stream flow_control info.stream_id)
            else (
              (* Receive request body *)
              let data_frame = recv_frame stream in
              let request, _ = Grpc_message.decode data_frame.Frame.payload in
              (* Call handler *)
              let response = handler stream request in
              (* Send response headers *)
              let resp_headers = Hpack.grpc_response_headers () in
              send_headers stream ~end_stream:false resp_headers;
              (* Send response body *)
              let body = Grpc_message.encode response in
              send_data stream ~end_stream:false body;
              (* Send trailers with grpc-status: 0 *)
              let trailers = Hpack.grpc_trailers 0 in
              send_headers stream ~end_stream:true trailers)
          | _ -> handle_connection_frame conn flow_control hpack_encoder frame
        done
      with
      | End_of_file -> Connection.close conn
      | Connection.Connection_error (code, msg) ->
        Connection.send_goaway
          conn
          ~last_stream_id:conn.Connection.last_stream_id
          ~error_code:code
          ~debug_data:msg;
        Connection.close conn
      | Invalid_argument msg ->
        Connection.send_goaway
          conn
          ~last_stream_id:conn.Connection.last_stream_id
          ~error_code:Frame.Error_code.protocol_error
          ~debug_data:msg;
        Connection.close conn
      | Failure msg ->
        Connection.send_goaway
          conn
          ~last_stream_id:conn.Connection.last_stream_id
          ~error_code:Frame.Error_code.protocol_error
          ~debug_data:msg;
        Connection.close conn
      | exn ->
        Connection.close conn;
        raise exn
    in
    (* Pre-warm buffer pool *)
    Buffer_pool.prewarm ~count_per_class:4;
    (* Accept connections *)
    while true do
      Eio.Net.accept_fork socket ~sw ~on_error:(fun _ -> ()) handle_connection
    done
  ;;
end

(** Initialize H2_lite (call once at startup) *)
let init () = Buffer_pool.prewarm ~count_per_class:8
