(** Minimal HTTP/2 server for h2spec compliance checks.

    Responds with 200 OK to any request after validating request headers
    and draining the request body. *)

open Printf
open H2_lite

exception Header_error of string

let port = ref 50090

let response_body = Cstruct.of_string "hello"

type request_state = {
  stream : stream;
  mutable content_length : int option;
  mutable body_bytes : int;
  mutable responded : bool;
  mutable trailers_seen : bool;
  mutable pending_data : Cstruct.t option;
}

let is_lowercase_header_name name =
  let len = String.length name in
  if len = 0 then
    false
  else
    let rec loop i =
      if i >= len then
        true
      else
        let c = name.[i] in
        if c >= 'A' && c <= 'Z' then
          false
        else
          loop (i + 1)
    in
    loop 0

let is_pseudo name =
  String.length name > 0 && name.[0] = ':'

let starts_with s prefix =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

let validate_request_headers ~is_trailers headers =
  let seen_regular = ref false in
  let seen_pseudo = Hashtbl.create 8 in
  let method_ = ref None in
  let scheme = ref None in
  let path = ref None in
  let authority = ref None in
  let content_lengths = ref [] in
  let add_pseudo name value =
    if Hashtbl.mem seen_pseudo name then
      raise (Header_error ("duplicate pseudo-header " ^ name));
    Hashtbl.add seen_pseudo name ();
    match name with
    | ":method" -> method_ := Some value
    | ":scheme" -> scheme := Some value
    | ":path" -> path := Some value
    | ":authority" -> authority := Some value
    | ":status" -> raise (Header_error "unexpected :status in request")
    | _ -> raise (Header_error ("unknown pseudo-header " ^ name))
  in
  let add_content_length value =
    let trimmed = String.trim value in
    match int_of_string_opt trimmed with
    | None -> raise (Header_error "invalid content-length")
    | Some n when n < 0 -> raise (Header_error "invalid content-length")
    | Some n -> content_lengths := n :: !content_lengths
  in
  let rec loop = function
    | [] -> ()
    | (name, value) :: rest ->
      if not (is_lowercase_header_name name) then
        raise (Header_error ("invalid header name " ^ name));
      if is_pseudo name then begin
        if is_trailers then
          raise (Header_error "pseudo-header in trailers");
        if !seen_regular then
          raise (Header_error "pseudo-header after regular headers");
        add_pseudo name value
      end else begin
        seen_regular := true;
        match name with
        | "connection" | "proxy-connection" | "keep-alive"
        | "transfer-encoding" | "upgrade" ->
          raise (Header_error ("connection-specific header " ^ name))
        | "te" ->
          if String.lowercase_ascii (String.trim value) <> "trailers" then
            raise (Header_error "invalid te header")
        | "content-length" ->
          add_content_length value
        | _ -> ()
      end;
      loop rest
  in
  loop headers;
  if not is_trailers then begin
    match !method_ with
    | None -> raise (Header_error "missing :method")
    | Some method_value ->
      if method_value = "" then
        raise (Header_error "empty :method");
      if String.uppercase_ascii method_value = "CONNECT" then begin
        if !authority = None then
          raise (Header_error "missing :authority for CONNECT");
        if !scheme <> None || !path <> None then
          raise (Header_error "invalid CONNECT pseudo-headers")
      end else begin
        if !scheme = None then
          raise (Header_error "missing :scheme");
        if !path = None then
          raise (Header_error "missing :path");
        match !path with
        | Some p when p = "" -> raise (Header_error "empty :path")
        | _ -> ()
      end
  end;
  match !content_lengths with
  | [] -> None
  | first :: rest ->
    if List.for_all (fun v -> v = first) rest then
      Some first
    else
      raise (Header_error "conflicting content-length")

let make_stream conn hpack_encoder hpack_decoder flow_control stream_id =
  {
    conn;
    id = stream_id;
    stream_state = Stream.create stream_id;
    hpack_encoder;
    hpack_decoder;
    flow_control;
  }

let send_response state =
  if not state.responded then begin
    state.responded <- true;
    let content_length = string_of_int (Cstruct.length response_body) in
    let headers = [ (":status", "200"); ("content-length", content_length) ] in
    state.pending_data <- Some response_body;
    send_headers state.stream ~end_stream:false headers
  end

let send_rst_stream conn flow_control stream_id error_code =
  let rst = Frame.make_rst_stream ~stream_id ~error_code in
  Connection.write_frame conn rst;
  Flow_control.remove_stream flow_control stream_id

let send_goaway conn error_code debug_data =
  Connection.send_goaway conn
    ~last_stream_id:conn.Connection.last_stream_id
    ~error_code
    ~debug_data;
  Connection.close conn

let () =
  let usage = "h2spec_server [--port 50090]" in
  Arg.parse
    [ ("--port", Arg.Set_int port, "Listen port (default: 50090)") ]
    (fun _ -> ())
    usage;
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, !port) in
  let socket = Eio.Net.listen ~sw ~backlog:128 ~reuse_addr:true net addr in
  printf "h2spec server listening on 127.0.0.1:%d\n%!" !port;
  while true do
    Eio.Net.accept_fork ~sw socket ~on_error:(fun exn ->
      eprintf "Connection error: %s\n%!" (Printexc.to_string exn))
      (fun client_socket _client_addr ->
        Eio.Switch.run @@ fun _inner_sw ->
        let conn =
          Connection.create
            ~settings:Connection.default_settings
            ~priority_scheduling:false
            client_socket
        in
        let flow_control = Flow_control.create () in
        let hpack_decoder = Hpack.create () in
        let hpack_encoder = Hpack.create () in
        let streams : (int32, request_state) Hashtbl.t = Hashtbl.create 16 in
        let max_stream_id_seen = ref 0l in
        let connection_error error_code debug_data =
          send_goaway conn error_code debug_data;
          raise Exit
        in
        let decode_headers header_block =
          let headers =
            try Hpack.decode hpack_decoder header_block with
            | Failure msg
            | Invalid_argument msg ->
              connection_error Frame.Error_code.compression_error msg
          in
          headers
        in
        let remove_stream stream_id =
          Hashtbl.remove streams stream_id;
          Flow_control.remove_stream flow_control stream_id
        in
        let finalize_stream state =
          if Stream.is_closed state.stream.stream_state then
            remove_stream state.stream.id
        in
        let try_send_pending_data state =
          match state.pending_data with
          | None -> ()
          | Some data ->
            let data_len = Cstruct.length data in
            let available =
              min
                (Flow_control.connection_send_window flow_control)
                (Flow_control.stream_send_window flow_control state.stream.id)
            in
            if available > 0 then begin
              let to_send = if data_len < available then data_len else available in
              let chunk =
                if to_send = data_len then
                  data
                else
                  Cstruct.sub data 0 to_send
              in
              let end_stream = to_send = data_len in
              send_data state.stream ~end_stream chunk;
              if end_stream then begin
                state.pending_data <- None;
                finalize_stream state
              end else
                state.pending_data <- Some (Cstruct.sub data to_send (data_len - to_send))
            end
        in
        let handle_data frame =
          let stream_id = frame.Frame.header.stream_id in
          if stream_id = 0l then
            connection_error Frame.Error_code.protocol_error
              "DATA on stream 0";
          match Hashtbl.find_opt streams stream_id with
          | None ->
            connection_error Frame.Error_code.stream_closed
              "DATA on closed or idle stream"
          | Some state ->
            let end_stream =
              Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.end_stream
            in
            (try
               Stream.transition_recv state.stream.stream_state `Data ~end_stream
             with Stream.Stream_error _ ->
               connection_error Frame.Error_code.stream_closed
                 "DATA on closed stream");
            let payload = frame.Frame.payload in
            let payload_len = Cstruct.length payload in
            let data_len =
              if Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.padded then begin
                if payload_len < 1 then
                  connection_error Frame.Error_code.protocol_error
                    "Invalid DATA padding";
                let pad_len = Cstruct.get_uint8 payload 0 in
                if pad_len > payload_len - 1 then
                  connection_error Frame.Error_code.protocol_error
                    "Invalid DATA padding";
                payload_len - 1 - pad_len
              end else
                payload_len
            in
            let updates =
              Flow_control.consume_recv flow_control stream_id data_len
            in
            if updates <> [] then begin
              let update_frames =
                List.map (fun (id, inc) ->
                  Frame.make_window_update ~stream_id:id
                    ~increment:(Int32.of_int inc)
                ) updates
              in
              Connection.write_frames conn update_frames
            end;
            state.body_bytes <- state.body_bytes + data_len;
            (match state.content_length with
             | Some expected when state.body_bytes > expected ->
               send_rst_stream conn flow_control stream_id
                 Frame.Error_code.protocol_error;
               remove_stream stream_id
             | _ ->
               if end_stream then begin
                 match state.content_length with
                 | Some expected when state.body_bytes <> expected ->
                   send_rst_stream conn flow_control stream_id
                     Frame.Error_code.protocol_error;
                   remove_stream stream_id
                 | _ ->
                   send_response state;
                   try_send_pending_data state
               end)
        in
        let handle_headers frame =
          let info = Connection.read_header_block ~first_frame:frame conn in
          let { Connection.stream_id; end_stream; header_block; priority; _ } = info in
          if stream_id = 0l then
            connection_error Frame.Error_code.protocol_error
              "HEADERS on stream 0";
          let existing = Hashtbl.find_opt streams stream_id in
          let is_new = existing = None in
          if is_new then begin
            if Int32.rem stream_id 2l = 0l then
              connection_error Frame.Error_code.protocol_error
                "client-initiated stream id must be odd";
            if Int32.compare stream_id !max_stream_id_seen <= 0 then
              connection_error Frame.Error_code.stream_closed
                "HEADERS on closed stream";
            max_stream_id_seen := stream_id
          end;
          let can_accept =
            if is_new &&
               Hashtbl.length streams >=
               conn.Connection.local_settings.max_concurrent_streams then begin
              send_rst_stream conn flow_control stream_id
                Frame.Error_code.refused_stream;
              false
            end else
              true
          in
          if not can_accept then
            ()
          else
            let headers =
              match decode_headers header_block with
              | headers -> headers
              | exception Header_error _ ->
                send_rst_stream conn flow_control stream_id
                  Frame.Error_code.protocol_error;
                remove_stream stream_id;
                []
            in
            if headers = [] then
              ()
            else
            let state_opt =
              match existing with
              | Some s -> Some s
              | None ->
                let stream =
                  make_stream conn hpack_encoder hpack_decoder flow_control stream_id
                in
                let content_length_opt =
                  match validate_request_headers ~is_trailers:false headers with
                  | value -> Some value
                  | exception Header_error _ ->
                    send_rst_stream conn flow_control stream_id
                      Frame.Error_code.protocol_error;
                    None
                in
                (match content_length_opt with
                 | None -> None
                 | Some content_length ->
                   let s = {
                     stream;
                     content_length;
                     body_bytes = 0;
                     responded = false;
                     trailers_seen = false;
                     pending_data = None;
                   } in
                   Hashtbl.add streams stream_id s;
                   Some s)
            in
            match state_opt with
            | None -> ()
            | Some state ->
            (match priority with
             | Some prio -> Connection.update_priority conn ~stream_id prio
             | None -> ());
            let trailer_ok =
              if not is_new then begin
                if state.trailers_seen then
                  connection_error Frame.Error_code.stream_closed
                    "extra HEADERS on closed stream";
                if not end_stream then begin
                  send_rst_stream conn flow_control stream_id
                    Frame.Error_code.protocol_error;
                  remove_stream stream_id;
                  false
                end else
                  match validate_request_headers ~is_trailers:true headers with
                  | _ ->
                    state.trailers_seen <- true;
                    true
                  | exception Header_error _ ->
                    send_rst_stream conn flow_control stream_id
                      Frame.Error_code.protocol_error;
                    remove_stream stream_id;
                    false
              end else
                true
            in
            if trailer_ok then begin
              (try
                 Stream.transition_recv state.stream.stream_state `Headers ~end_stream
               with Stream.Stream_error _ ->
                 connection_error Frame.Error_code.stream_closed
                   "HEADERS on closed stream");
              if end_stream then begin
                match state.content_length with
              | Some expected when state.body_bytes <> expected ->
                send_rst_stream conn flow_control stream_id
                  Frame.Error_code.protocol_error;
                remove_stream stream_id
              | _ ->
                send_response state;
                try_send_pending_data state
            end
            end
        in
        let handle_settings frame =
          if frame.Frame.header.stream_id <> 0l then
            connection_error Frame.Error_code.protocol_error
              "SETTINGS on non-zero stream";
          let payload_len = Cstruct.length frame.Frame.payload in
          if Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.ack then begin
            if payload_len <> 0 then
              connection_error Frame.Error_code.frame_size_error
                "SETTINGS ack with payload"
          end else begin
            if payload_len mod 6 <> 0 then
              connection_error Frame.Error_code.frame_size_error
                "Invalid SETTINGS payload length";
            let settings = Connection.parse_settings_payload frame.Frame.payload in
            List.iter (fun (id, value) ->
              if id = Frame.Settings_id.initial_window_size &&
                 Int32.logand value 0x80000000l <> 0l then
                connection_error Frame.Error_code.flow_control_error
                  "FLOW_CONTROL_ERROR: initial_window_size too large"
            ) settings;
            (try
               Connection.apply_peer_settings conn settings;
               Flow_control.update_initial_window_size
                 flow_control conn.Connection.peer_settings.initial_window_size;
               Hpack.set_max_size hpack_encoder
                 conn.Connection.peer_settings.header_table_size;
               Connection.send_settings_ack conn
               ;
               Hashtbl.iter (fun _ state -> try_send_pending_data state) streams
             with
             | Failure msg when starts_with msg "FLOW_CONTROL_ERROR" ->
               connection_error Frame.Error_code.flow_control_error msg
             | Failure msg ->
               connection_error Frame.Error_code.protocol_error msg
             | Invalid_argument msg ->
               connection_error Frame.Error_code.protocol_error msg)
          end
        in
        let handle_window_update frame =
          let stream_id = frame.Frame.header.stream_id in
          if Cstruct.length frame.Frame.payload <> 4 then
            connection_error Frame.Error_code.protocol_error
              "Invalid WINDOW_UPDATE payload";
          let raw = Cstruct.BE.get_uint32 frame.Frame.payload 0 in
          let increment = Int32.logand raw 0x7FFFFFFFl |> Int32.to_int in
          if increment = 0 then begin
            if stream_id = 0l then
              connection_error Frame.Error_code.protocol_error
                "WINDOW_UPDATE increment 0"
            else begin
              send_rst_stream conn flow_control stream_id
                Frame.Error_code.protocol_error;
              remove_stream stream_id
            end
          end else begin
            let stream_known = Hashtbl.mem streams stream_id in
            if stream_id <> 0l && not stream_known then begin
              if Int32.compare stream_id !max_stream_id_seen <= 0 then
                ()
              else
                connection_error Frame.Error_code.protocol_error
                  "WINDOW_UPDATE on idle stream"
            end else
              (try Flow_control.update flow_control stream_id increment with
               | Failure msg when starts_with msg "FLOW_CONTROL_ERROR" ->
                 if stream_id = 0l then
                   connection_error Frame.Error_code.flow_control_error msg
                 else begin
                   send_rst_stream conn flow_control stream_id
                     Frame.Error_code.flow_control_error;
                   remove_stream stream_id
                 end);
              if stream_id = 0l then
                Hashtbl.iter (fun _ state -> try_send_pending_data state) streams
              else
                (match Hashtbl.find_opt streams stream_id with
                 | Some state -> try_send_pending_data state
                 | None -> ())
          end
        in
        let handle_priority frame =
          let stream_id = frame.Frame.header.stream_id in
          if stream_id = 0l then
            connection_error Frame.Error_code.protocol_error
              "PRIORITY on stream 0";
          let (prio, _) =
            Frame.parse_priority frame.Frame.payload ~offset:0
          in
          if prio.dependency = stream_id || prio.weight < 1 || prio.weight > 256 then begin
            send_rst_stream conn flow_control stream_id
              Frame.Error_code.protocol_error;
            if Hashtbl.mem streams stream_id then
              remove_stream stream_id
          end else begin
            (match Hashtbl.find_opt streams stream_id with
             | Some state -> Stream.set_priority state.stream.stream_state prio
             | None -> ());
            Connection.update_priority conn ~stream_id prio
          end
        in
        try
          Connection.server_handshake conn;
          Flow_control.update_initial_window_size
            flow_control conn.Connection.peer_settings.initial_window_size;
          Flow_control.update_recv_initial_window_size
            flow_control conn.Connection.local_settings.initial_window_size;
          Hpack.set_max_size hpack_encoder
            conn.Connection.peer_settings.header_table_size;
          let rec loop () =
            let frame = Connection.read_frame conn in
            match frame.Frame.header.frame_type with
            | Frame.Settings ->
              handle_settings frame;
              loop ()
            | Frame.Ping
            | Frame.GoAway ->
              if frame.Frame.header.stream_id <> 0l then
                connection_error Frame.Error_code.protocol_error
                  "connection frame on non-zero stream"
              else begin
                handle_connection_frame conn flow_control hpack_encoder frame;
                loop ()
              end
            | Frame.WindowUpdate ->
              handle_window_update frame;
              loop ()
            | Frame.Headers ->
              handle_headers frame;
              loop ()
            | Frame.Data ->
              handle_data frame;
              loop ()
            | Frame.Priority ->
              handle_priority frame;
              loop ()
            | Frame.RstStream ->
              let stream_id = frame.Frame.header.stream_id in
              if stream_id = 0l then
                connection_error Frame.Error_code.protocol_error
                  "RST_STREAM on stream 0";
              if Cstruct.length frame.Frame.payload <> 4 then
                connection_error Frame.Error_code.frame_size_error
                  "Invalid RST_STREAM payload length";
              if Int32.compare stream_id !max_stream_id_seen > 0 then
                connection_error Frame.Error_code.protocol_error
                  "RST_STREAM on idle stream";
              remove_stream stream_id;
              loop ()
            | Frame.Continuation ->
              connection_error Frame.Error_code.protocol_error
                "Unexpected CONTINUATION"
            | Frame.PushPromise ->
              connection_error Frame.Error_code.protocol_error
                "PUSH_PROMISE not allowed"
            | _ ->
              loop ()
          in
          loop ()
        with
        | Exit ->
          ()
        | End_of_file ->
          Connection.close conn
        | Connection.Connection_error (code, msg) ->
          send_goaway conn code msg
        | Invalid_argument msg ->
          send_goaway conn Frame.Error_code.protocol_error msg
        | Failure msg ->
          send_goaway conn Frame.Error_code.protocol_error msg)
  done
