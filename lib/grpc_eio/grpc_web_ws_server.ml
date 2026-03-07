(** gRPC-Web WebSocket gateway (experimental). *)

module Http1 = Grpc_web_http1
module Web = Grpc_web

type config =
  { addr : Eio.Net.Sockaddr.stream
  ; tls : Tls_config.t option
  ; max_frame_size : int
  ; subprotocols : string list
  }

let default_config (server : Server.t) =
  let base = Server.config server in
  let port = base.port + 2 in
  { addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port)
  ; tls = base.tls
  ; max_frame_size = base.max_message_size * 2
  ; subprotocols = [ "grpc-websockets" ]
  }
;;

let request_codec_of_metadata (server : Server.t) (metadata : (string * string) list) =
  match List.assoc_opt "grpc-encoding" metadata with
  | None -> Ok Grpc_core.Codec.identity
  | Some encoding ->
    (match
       Grpc_core.Codec.find_by_name ~supported:(Server.config server).codecs encoding
     with
     | Some codec -> Ok codec
     | None ->
       Error
         Grpc_core.Status.
           { code = Unimplemented
           ; message = Printf.sprintf "Unsupported grpc-encoding: %s" encoding
           ; details = None
           })
;;

let response_codec_of_metadata (server : Server.t) (metadata : (string * string) list) =
  match List.assoc_opt "grpc-accept-encoding" metadata with
  | None -> Ok Grpc_core.Codec.identity
  | Some accepted ->
    let accepted_list = Grpc_core.Codec.parse_accept accepted in
    let accepted_list =
      if List.mem "identity" accepted_list
      then accepted_list
      else "identity" :: accepted_list
    in
    let supported = (Server.config server).codecs in
    (match
       List.find_opt
         (fun c ->
            List.mem (Grpc_core.Codec.normalize_name c.Grpc_core.Codec.name) accepted_list)
         supported
     with
     | Some codec -> Ok codec
     | None ->
       if List.mem "identity" accepted_list
       then Ok Grpc_core.Codec.identity
       else
         Error
           Grpc_core.Status.
             { code = Unimplemented
             ; message =
                 Printf.sprintf
                   "No compatible grpc-encoding in grpc-accept-encoding: %s"
                   accepted
             ; details = None
             })
;;

let timeout_seconds_of_metadata (server : Server.t) (metadata : (string * string) list) =
  match List.assoc_opt "grpc-timeout" metadata with
  | None ->
    (Server.config server).default_timeout |> Option.map Grpc_core.Timeout.to_seconds
  | Some header ->
    (match Grpc_core.Timeout.parse header with
     | None -> None
     | Some timeout -> Some (Grpc_core.Timeout.to_seconds timeout))
;;

let deadline_status =
  Grpc_core.Status.
    { code = Deadline_exceeded; message = "Deadline exceeded"; details = None }
;;

let grpc_status_trailers (status : Grpc_core.Status.t) =
  let trailers =
    [ ( "grpc-status"
      , string_of_int (Grpc_core.Status.code_to_int status.Grpc_core.Status.code) )
    ; "grpc-message", Web.percent_encode status.Grpc_core.Status.message
    ]
  in
  match status.Grpc_core.Status.details with
  | None -> trailers
  | Some details -> ("grpc-status-details-bin", details) :: trailers
;;

let add_encoding_trailer ~codec trailers =
  if Grpc_core.Codec.is_identity codec || List.mem_assoc "grpc-encoding" trailers
  then trailers
  else ("grpc-encoding", codec.Grpc_core.Codec.name) :: trailers
;;

let send_plain ~flow ~status ~reason =
  let headers = [ "connection", "close"; "content-length", "0" ] in
  Http1.write_response flow ~status ~reason ~headers ~body:""
;;

let header_tokens value =
  value
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun v -> v <> "")
;;

let header_contains headers name token =
  match Http1.header_value headers name with
  | None -> false
  | Some value ->
    let token = String.lowercase_ascii token in
    header_tokens value |> List.exists (fun v -> String.lowercase_ascii v = token)
;;

let select_subprotocol ~supported ~requested =
  match requested with
  | None -> None
  | Some value ->
    let requested =
      value
      |> String.split_on_char ','
      |> List.map String.trim
      |> List.filter (fun v -> v <> "")
    in
    List.find_opt (fun proto -> List.mem proto requested) supported
;;

let websocket_accept key =
  let magic = key ^ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" in
  let digest = Digestif.SHA1.digest_string magic |> Digestif.SHA1.to_raw_string in
  Web.Base64.encode digest
;;

type ws_frame =
  | Ws_binary of string
  | Ws_text of string
  | Ws_ping of string
  | Ws_pong of string
  | Ws_close

let read_byte reader =
  let s = Eio.Buf_read.take 1 reader in
  Char.code s.[0]
;;

let read_uint16_be reader =
  let s = Eio.Buf_read.take 2 reader in
  (Char.code s.[0] lsl 8) lor Char.code s.[1]
;;

let read_uint64_be reader =
  let s = Eio.Buf_read.take 8 reader in
  let open Int64 in
  let b i = of_int (Char.code s.[i]) in
  logor
    (shift_left (b 0) 56)
    (logor
       (shift_left (b 1) 48)
       (logor
          (shift_left (b 2) 40)
          (logor
             (shift_left (b 3) 32)
             (logor
                (shift_left (b 4) 24)
                (logor (shift_left (b 5) 16) (logor (shift_left (b 6) 8) (b 7)))))))
;;

let unmask_payload payload mask =
  let len = String.length payload in
  let buf = Bytes.of_string payload in
  for i = 0 to len - 1 do
    let m = Char.code mask.[i mod 4] in
    let c = Char.code (Bytes.get buf i) in
    Bytes.set buf i (Char.chr (c lxor m))
  done;
  Bytes.to_string buf
;;

let read_ws_frame reader ~max_frame_size =
  let b1 = read_byte reader in
  let b2 = read_byte reader in
  let fin = b1 land 0x80 <> 0 in
  let opcode = b1 land 0x0F in
  let masked = b2 land 0x80 <> 0 in
  let len_code = b2 land 0x7F in
  if not fin then failwith "Fragmented WebSocket frames are not supported";
  if not masked then failwith "Client WebSocket frames must be masked";
  let payload_len =
    match len_code with
    | n when n < 126 -> n
    | 126 -> read_uint16_be reader
    | 127 ->
      let len64 = read_uint64_be reader in
      if len64 > Int64.of_int max_int then failwith "WebSocket frame too large";
      Int64.to_int len64
    | _ -> failwith "Invalid WebSocket length"
  in
  if payload_len > max_frame_size then failwith "WebSocket payload too large";
  let mask = Eio.Buf_read.take 4 reader in
  let payload = Eio.Buf_read.take payload_len reader |> fun s -> unmask_payload s mask in
  match opcode with
  | 0x1 -> Ws_text payload
  | 0x2 -> Ws_binary payload
  | 0x8 -> Ws_close
  | 0x9 -> Ws_ping payload
  | 0xA -> Ws_pong payload
  | _ -> failwith (Printf.sprintf "Unsupported WebSocket opcode: 0x%02X" opcode)
;;

let write_ws_frame flow ~opcode payload =
  let len = String.length payload in
  let header =
    if len < 126
    then (
      let buf = Bytes.create 2 in
      Bytes.set buf 0 (Char.chr (0x80 lor opcode));
      Bytes.set buf 1 (Char.chr len);
      buf)
    else if len < 65536
    then (
      let buf = Bytes.create 4 in
      Bytes.set buf 0 (Char.chr (0x80 lor opcode));
      Bytes.set buf 1 (Char.chr 126);
      Bytes.set buf 2 (Char.chr ((len lsr 8) land 0xFF));
      Bytes.set buf 3 (Char.chr (len land 0xFF));
      buf)
    else (
      let buf = Bytes.create 10 in
      let len64 = Int64.of_int len in
      Bytes.set buf 0 (Char.chr (0x80 lor opcode));
      Bytes.set buf 1 (Char.chr 127);
      for i = 0 to 7 do
        let shift = (7 - i) * 8 in
        let chunk = Int64.shift_right_logical len64 shift in
        let byte = Int64.(to_int (logand chunk 0xFFL)) in
        Bytes.set buf (2 + i) (Char.chr byte)
      done;
      buf)
  in
  Eio.Flow.write flow [ Cstruct.of_bytes header; Cstruct.of_string payload ]
;;

let send_ws_binary flow payload = write_ws_frame flow ~opcode:0x2 payload
let send_ws_pong flow payload = write_ws_frame flow ~opcode:0xA payload
let send_ws_close flow = write_ws_frame flow ~opcode:0x8 ""

let read_request_messages ~reader ~flow ~codec ~max_size ~max_frame_size =
  let pending = ref "" in
  let messages = ref [] in
  let done_reading = ref false in
  let handle_frames frames =
    let rec walk = function
      | [] -> Ok ()
      | Web.Message frame :: rest ->
        (match Grpc_core.Message.decode ~max_size ~codec frame with
         | Ok msg ->
           messages := msg :: !messages;
           walk rest
         | Error e ->
           Error
             Grpc_core.Status.
               { code = Invalid_argument
               ; message = Printf.sprintf "Decode error: %s" e
               ; details = None
               })
      | Web.Trailers _ :: _ ->
        done_reading := true;
        Ok ()
    in
    walk frames
  in
  let rec loop () =
    if !done_reading
    then Ok (List.rev !messages)
    else (
      let frame = read_ws_frame reader ~max_frame_size in
      match frame with
      | Ws_ping payload ->
        send_ws_pong flow payload;
        loop ()
      | Ws_pong _ -> loop ()
      | Ws_close -> Ok (List.rev !messages)
      | Ws_text _ ->
        Error
          Grpc_core.Status.
            { code = Invalid_argument
            ; message = "Text WebSocket frames not supported"
            ; details = None
            }
      | Ws_binary payload ->
        let combined = !pending ^ payload in
        (match Web.decode_frames_partial combined with
         | Error e ->
           Error Grpc_core.Status.{ code = Invalid_argument; message = e; details = None }
         | Ok (frames, rest) ->
           pending := rest;
           (match handle_frames frames with
            | Ok () -> loop ()
            | Error _ as err -> err)))
  in
  loop ()
;;

let stream_request_messages ~sw ~reader ~flow ~codec ~max_size ~max_frame_size =
  let pending = ref "" in
  let request_stream = Grpc_stream.create 16 in
  let done_reading = ref false in
  let error_ref = ref None in
  let error_promise, error_resolver = Eio.Promise.create () in
  let set_error status =
    if !error_ref = None
    then (
      error_ref := Some status;
      Eio.Promise.resolve error_resolver status);
    if not !done_reading
    then (
      done_reading := true;
      Grpc_stream.close request_stream)
  in
  let handle_frames frames =
    let rec walk = function
      | [] -> ()
      | Web.Message frame :: rest ->
        (match Grpc_core.Message.decode ~max_size ~codec frame with
         | Ok msg ->
           Grpc_stream.add request_stream msg;
           walk rest
         | Error e ->
           set_error
             Grpc_core.Status.
               { code = Invalid_argument
               ; message = Printf.sprintf "Decode error: %s" e
               ; details = None
               })
      | Web.Trailers _ :: _ ->
        done_reading := true;
        Grpc_stream.close request_stream
    in
    walk frames
  in
  let rec loop () =
    if !done_reading
    then ()
    else (
      let frame = read_ws_frame reader ~max_frame_size in
      match frame with
      | Ws_ping payload ->
        send_ws_pong flow payload;
        loop ()
      | Ws_pong _ -> loop ()
      | Ws_close ->
        done_reading := true;
        Grpc_stream.close request_stream
      | Ws_text _ ->
        set_error
          Grpc_core.Status.
            { code = Invalid_argument
            ; message = "Text WebSocket frames not supported"
            ; details = None
            }
      | Ws_binary payload ->
        let combined = !pending ^ payload in
        (match Web.decode_frames_partial combined with
         | Error e ->
           set_error
             Grpc_core.Status.{ code = Invalid_argument; message = e; details = None }
         | Ok (frames, rest) ->
           pending := rest;
           handle_frames frames;
           loop ()))
  in
  Eio.Fiber.fork ~sw (fun () ->
    try loop () with
    | End_of_file ->
      if not !done_reading
      then (
        done_reading := true;
        Grpc_stream.close request_stream)
    | Failure msg ->
      set_error
        Grpc_core.Status.{ code = Invalid_argument; message = msg; details = None }
    | exn ->
      set_error
        Grpc_core.Status.
          { code = Unknown; message = Printexc.to_string exn; details = None });
  request_stream, error_ref, error_promise
;;

let send_unary_response ~flow ~codec ~resp_body ~trailers =
  let trailers =
    if List.mem_assoc "grpc-status" trailers
    then trailers
    else ("grpc-status", "0") :: trailers
  in
  let trailers = add_encoding_trailer ~codec trailers in
  send_ws_binary flow resp_body;
  let trailer_frame = Web.encode_frame (Web.Trailers trailers) in
  send_ws_binary flow trailer_frame
;;

let send_streaming_response
      ~flow
      ~clock
      ~timeout
      ~codec
      ~response_stream
      ?error_promise
      ()
  =
  let deadline = Option.map (fun t -> Eio.Time.now clock +. t) timeout in
  let deadline_exceeded () =
    match deadline with
    | None -> false
    | Some d -> Eio.Time.now clock >= d
  in
  let error_status = ref None in
  let rec write_messages () =
    if deadline_exceeded ()
    then error_status := Some deadline_status
    else (
      let wait_next () =
        match error_promise with
        | None -> `Msg (Grpc_stream.take response_stream)
        | Some promise ->
          Eio.Fiber.first
            (fun () -> `Msg (Grpc_stream.take response_stream))
            (fun () -> `Err (Eio.Promise.await promise))
      in
      let next =
        try
          match deadline with
          | None -> Some (wait_next ())
          | Some d ->
            let remaining = d -. Eio.Time.now clock in
            if remaining <= 0.0
            then (
              error_status := Some deadline_status;
              None)
            else Some (Eio.Time.with_timeout_exn clock remaining wait_next)
        with
        | End_of_file -> None
        | Eio.Time.Timeout ->
          error_status := Some deadline_status;
          None
      in
      match next with
      | None -> ()
      | Some (`Err status) -> error_status := Some status
      | Some (`Msg msg) ->
        (match Grpc_core.Message.encode ~codec msg with
         | Error e ->
           error_status
           := Some Grpc_core.Status.{ code = Internal; message = e; details = None }
         | Ok frame ->
           send_ws_binary flow frame;
           write_messages ()))
  in
  write_messages ();
  let trailers =
    match !error_status with
    | None -> [ "grpc-status", "0" ]
    | Some status -> grpc_status_trailers status
  in
  let trailers = add_encoding_trailer ~codec trailers in
  send_ws_binary flow (Web.encode_frame (Web.Trailers trailers))
;;

let send_grpc_error ~flow (status : Grpc_core.Status.t) =
  let trailers = grpc_status_trailers status in
  let trailer_frame = Web.encode_frame (Web.Trailers trailers) in
  send_ws_binary flow trailer_frame
;;

let handle_grpc_websocket
      ~sw
      ~clock
      ~server
      ~config
      ~flow
      ~reader
      ~(path : string)
      ~(metadata : (string * string) list)
      ~(method_def : Service.method_def)
      ~(request_codec : Grpc_core.Codec.t)
      ~(response_codec : Grpc_core.Codec.t)
  =
  let max_size = (Server.config server).max_message_size in
  let read_result =
    read_request_messages
      ~reader
      ~flow
      ~codec:request_codec
      ~max_size
      ~max_frame_size:config.max_frame_size
  in
  match read_result with
  | Error status ->
    send_grpc_error ~flow status;
    send_ws_close flow
  | Ok messages ->
    (match method_def.Service.method_type with
     | Service.Unary ->
       (match messages with
        | [ request_data ] ->
          let result =
            Server.handle_decoded_request
              server
              ~clock
              ~path
              ~metadata
              ~request_data
              ~response_codec
              ~method_def
          in
          (match result with
           | Ok (resp_body, trailers, resp_codec) ->
             send_unary_response ~flow ~codec:resp_codec ~resp_body ~trailers;
             send_ws_close flow
           | Error status ->
             send_grpc_error ~flow status;
             send_ws_close flow)
        | _ ->
          let status =
            Grpc_core.Status.
              { code = Invalid_argument
              ; message = "Unary request must contain exactly one message"
              ; details = None
              }
          in
          send_grpc_error ~flow status;
          send_ws_close flow)
     | Service.ServerStreaming ->
       (match messages with
        | [ request_data ] ->
          (match method_def.handler with
           | `ServerStreaming handler ->
             let response_stream = handler request_data in
             let timeout_seconds = timeout_seconds_of_metadata server metadata in
             send_streaming_response
               ~flow
               ~clock
               ~timeout:timeout_seconds
               ~codec:response_codec
               ~response_stream
               ();
             send_ws_close flow
           | _ ->
             let status =
               Grpc_core.Status.
                 { code = Internal; message = "Handler type mismatch"; details = None }
             in
             send_grpc_error ~flow status;
             send_ws_close flow)
        | _ ->
          let status =
            Grpc_core.Status.
              { code = Invalid_argument
              ; message = "Server streaming request must contain exactly one message"
              ; details = None
              }
          in
          send_grpc_error ~flow status;
          send_ws_close flow)
     | Service.ClientStreaming ->
       (match method_def.handler with
        | `ClientStreaming handler ->
          let request_stream, request_error, _error_promise =
            stream_request_messages
              ~sw
              ~reader
              ~flow
              ~codec:request_codec
              ~max_size
              ~max_frame_size:config.max_frame_size
          in
          let timeout_seconds = timeout_seconds_of_metadata server metadata in
          let response =
            match timeout_seconds with
            | None -> Ok (handler request_stream)
            | Some secs ->
              (try
                 Ok
                   (Eio.Time.with_timeout_exn clock secs (fun () ->
                      handler request_stream))
               with
               | Eio.Time.Timeout -> Error deadline_status)
          in
          (match !request_error with
           | Some status ->
             send_grpc_error ~flow status;
             send_ws_close flow
           | None ->
             (match response with
              | Ok resp_body ->
                let resp =
                  match Grpc_core.Message.encode ~codec:response_codec resp_body with
                  | Ok frame -> Ok frame
                  | Error e ->
                    Error
                      Grpc_core.Status.{ code = Internal; message = e; details = None }
                in
                (match resp with
                 | Ok frame ->
                   send_unary_response
                     ~flow
                     ~codec:response_codec
                     ~resp_body:frame
                     ~trailers:[];
                   send_ws_close flow
                 | Error status ->
                   send_grpc_error ~flow status;
                   send_ws_close flow)
              | Error status ->
                send_grpc_error ~flow status;
                send_ws_close flow))
        | _ ->
          let status =
            Grpc_core.Status.
              { code = Internal; message = "Handler type mismatch"; details = None }
          in
          send_grpc_error ~flow status;
          send_ws_close flow)
     | Service.BidiStreaming ->
       (match method_def.handler with
        | `Bidi handler ->
          let request_stream, _request_error, error_promise =
            stream_request_messages
              ~sw
              ~reader
              ~flow
              ~codec:request_codec
              ~max_size
              ~max_frame_size:config.max_frame_size
          in
          let response_stream = handler ~sw request_stream in
          let timeout_seconds = timeout_seconds_of_metadata server metadata in
          send_streaming_response
            ~flow
            ~clock
            ~timeout:timeout_seconds
            ~codec:response_codec
            ~response_stream
            ~error_promise
            ();
          send_ws_close flow
        | _ ->
          let status =
            Grpc_core.Status.
              { code = Internal; message = "Handler type mismatch"; details = None }
          in
          send_grpc_error ~flow status;
          send_ws_close flow))
;;

let serve ?config ~sw ~env (server : Server.t) =
  let net = Eio.Stdenv.net env in
  let config = Option.value ~default:(default_config server) config in
  let tls_server_config =
    match config.tls with
    | Some tls ->
      (match Tls_config.load_http1 tls with
       | Ok cfg ->
         Eio.traceln "gRPC-Web WebSocket TLS enabled (ALPN: http/1.1)";
         Some cfg
       | Error msg -> failwith ("TLS configuration error: " ^ msg))
    | None -> None
  in
  let socket = Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true config.addr in
  let addr = Format.asprintf "%a" Eio.Net.Sockaddr.pp config.addr in
  Log.info "gRPC-Web WebSocket gateway on %s" addr;
  let handle_connection flow _addr =
    let upgraded = ref false in
    try
      let reader = Eio.Buf_read.of_flow ~max_size:(config.max_frame_size + 1024) flow in
      let req = Http1.read_request reader ~max_header_size:16384 ~max_body_size:0 in
      if String.uppercase_ascii req.meth = "GET"
      then (
        let upgrade_ok = header_contains req.headers "upgrade" "websocket" in
        let conn_ok = header_contains req.headers "connection" "upgrade" in
        let version_ok =
          match Http1.header_value req.headers "sec-websocket-version" with
          | Some "13" -> true
          | _ -> false
        in
        let key = Http1.header_value req.headers "sec-websocket-key" in
        let path =
          match String.split_on_char '?' req.target with
          | [] -> req.target
          | p :: _ -> p
        in
        if (not upgrade_ok) || (not conn_ok) || (not version_ok) || key = None
        then send_plain ~flow ~status:400 ~reason:"Bad Request"
        else (
          match Server.lookup_method server path with
          | Error status ->
            send_plain ~flow ~status:404 ~reason:status.Grpc_core.Status.message
          | Ok (_service, method_def, _) ->
            let metadata = req.headers in
            (match
               ( request_codec_of_metadata server metadata
               , response_codec_of_metadata server metadata )
             with
             | Error status, _ | _, Error status ->
               send_plain ~flow ~status:400 ~reason:status.Grpc_core.Status.message
             | Ok request_codec, Ok response_codec ->
               let accept_key = websocket_accept (Option.get key) in
               let requested_proto =
                 Http1.header_value req.headers "sec-websocket-protocol"
               in
               let selected_proto =
                 select_subprotocol
                   ~supported:config.subprotocols
                   ~requested:requested_proto
               in
               let headers =
                 [ "upgrade", "websocket"
                 ; "connection", "Upgrade"
                 ; "sec-websocket-accept", accept_key
                 ]
               in
               let headers =
                 match selected_proto with
                 | None -> headers
                 | Some proto -> ("sec-websocket-protocol", proto) :: headers
               in
               Http1.write_response_headers
                 flow
                 ~status:101
                 ~reason:"Switching Protocols"
                 ~headers;
               upgraded := true;
               handle_grpc_websocket
                 ~sw
                 ~clock:(Eio.Stdenv.clock env)
                 ~server
                 ~config
                 ~flow
                 ~reader
                 ~path
                 ~metadata
                 ~method_def
                 ~request_codec
                 ~response_codec)))
      else send_plain ~flow ~status:405 ~reason:"Method Not Allowed"
    with
    | End_of_file -> ()
    | Failure msg ->
      if !upgraded
      then send_ws_close flow
      else send_plain ~flow ~status:400 ~reason:"Bad Request";
      Eio.traceln "gRPC-Web WebSocket parse error: %s" msg
    | exn ->
      if !upgraded
      then send_ws_close flow
      else send_plain ~flow ~status:500 ~reason:"Internal Server Error";
      Eio.traceln "gRPC-Web WebSocket error: %s" (Printexc.to_string exn)
  in
  let accept_plain sock addr = handle_connection sock addr in
  let accept_tls sock addr =
    match tls_server_config with
    | None -> accept_plain sock addr
    | Some tls_cfg ->
      let tls_flow = Tls_eio.server_of_flow tls_cfg sock in
      handle_connection tls_flow addr
  in
  while true do
    Eio.Net.accept_fork
      socket
      ~sw
      ~on_error:(fun exn ->
        Eio.traceln "gRPC-Web WebSocket connection error: %s" (Printexc.to_string exn))
      accept_tls
  done
;;
