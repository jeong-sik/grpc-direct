(** gRPC-Web server over HTTP/1.1 with CORS support. *)

module Http1 = Grpc_web_http1
module Web = Grpc_web

type cors_config = {
  allow_origin : string;
  allow_methods : string list;
  allow_headers : string list;
  expose_headers : string list;
  allow_credentials : bool;
  max_age : int option;
}

let default_cors = {
  allow_origin = "*";
  allow_methods = ["POST"; "OPTIONS"];
  allow_headers = [
    "content-type";
    "x-grpc-web";
    "x-user-agent";
    "grpc-timeout";
    "grpc-encoding";
    "grpc-accept-encoding";
  ];
  expose_headers = [
    "grpc-status";
    "grpc-message";
    "grpc-status-details-bin";
  ];
  allow_credentials = false;
  max_age = Some 7200;
}

type config = {
  addr : Eio.Net.Sockaddr.stream;
  cors : cors_config;
  tls : Tls_config.t option;
  max_request_body : int;
}

let default_config (server : Server.t) =
  let base = Server.config server in
  let port = base.port + 1 in
  {
    addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port);
    cors = default_cors;
    tls = base.tls;
    max_request_body = base.max_message_size * 2;
  }

let supported_encodings (server : Server.t) =
  let cfg = Server.config server in
  cfg.codecs |> List.map (fun c -> c.Grpc_core.Codec.name) |> String.concat ", "

let request_codec_of_metadata (server : Server.t) (metadata : (string * string) list) =
  match List.assoc_opt "grpc-encoding" metadata with
  | None -> Ok Grpc_core.Codec.identity
  | Some encoding ->
      (match Grpc_core.Codec.find_by_name ~supported:(Server.config server).codecs encoding with
       | Some codec -> Ok codec
       | None ->
           Error Grpc_core.Status.{
             code = Unimplemented;
             message = Printf.sprintf "Unsupported grpc-encoding: %s" encoding;
             details = None;
           })

let response_codec_of_metadata (server : Server.t) (metadata : (string * string) list) =
  match List.assoc_opt "grpc-accept-encoding" metadata with
  | None -> Ok Grpc_core.Codec.identity
  | Some accepted ->
      let accepted_list = Grpc_core.Codec.parse_accept accepted in
      let accepted_list =
        if List.mem "identity" accepted_list then accepted_list else "identity" :: accepted_list
      in
      let supported = (Server.config server).codecs in
      (match List.find_opt (fun c ->
         List.mem (Grpc_core.Codec.normalize_name c.Grpc_core.Codec.name) accepted_list
       ) supported with
       | Some codec -> Ok codec
       | None ->
           if List.mem "identity" accepted_list then Ok Grpc_core.Codec.identity
           else Error Grpc_core.Status.{
             code = Unimplemented;
             message = Printf.sprintf "No compatible grpc-encoding in grpc-accept-encoding: %s" accepted;
             details = None;
           })

let timeout_seconds_of_metadata (server : Server.t) (metadata : (string * string) list) =
  match List.assoc_opt "grpc-timeout" metadata with
  | None -> (Server.config server).default_timeout |> Option.map Grpc_core.Timeout.to_seconds
  | Some header ->
      match Grpc_core.Timeout.parse header with
      | None -> None
      | Some timeout -> Some (Grpc_core.Timeout.to_seconds timeout)

let deadline_status =
  Grpc_core.Status.{ code = Deadline_exceeded; message = "Deadline exceeded"; details = None }

let cors_headers (cors : cors_config) =
  let base = [
    ("access-control-allow-origin", cors.allow_origin);
    ("access-control-expose-headers", String.concat ", " cors.expose_headers);
  ] in
  let base =
    if cors.allow_credentials
    then ("access-control-allow-credentials", "true") :: base
    else base
  in
  base

let preflight_headers (cors : cors_config) =
  let headers = cors_headers cors in
  let headers = ("access-control-allow-methods", String.concat ", " cors.allow_methods) :: headers in
  let headers = ("access-control-allow-headers", String.concat ", " cors.allow_headers) :: headers in
  let headers = match cors.max_age with
    | None -> headers
    | Some secs -> ("access-control-max-age", string_of_int secs) :: headers
  in
  headers

let grpc_web_headers ~cors ~mode ~encodings ~codec =
  let headers = [
    ("content-type", Web.content_type mode);
    ("grpc-accept-encoding", encodings);
  ] in
  let headers =
    if Grpc_core.Codec.is_identity codec then headers
    else ("grpc-encoding", codec.Grpc_core.Codec.name) :: headers
  in
  let headers = cors_headers cors @ headers in
  ("connection", "close") :: headers

let send_plain ~flow ~status ~reason ~headers ~body =
  let headers = ("connection", "close") :: headers in
  Http1.write_response flow ~status ~reason ~headers ~body

let grpc_status_trailers (status : Grpc_core.Status.t) =
  let trailers = [
    ("grpc-status", string_of_int (Grpc_core.Status.code_to_int status.Grpc_core.Status.code));
    ("grpc-message", Web.percent_encode status.Grpc_core.Status.message);
  ] in
  match status.Grpc_core.Status.details with
  | None -> trailers
  | Some details -> ("grpc-status-details-bin", details) :: trailers

let send_grpc_web_error ~flow ~cors ~mode ~encodings (status : Grpc_core.Status.t) =
  let trailers = grpc_status_trailers status in
  let body_bin = Web.encode_frame (Web.Trailers trailers) in
  let body =
    match mode with
    | Web.Binary -> body_bin
    | Web.Text -> Web.Base64.encode body_bin
  in
  let headers = grpc_web_headers ~cors ~mode ~encodings ~codec:Grpc_core.Codec.identity in
  let headers = ("content-length", string_of_int (String.length body)) :: headers in
  send_plain ~flow ~status:200 ~reason:"OK" ~headers ~body

let decode_request_frames ~mode ~body =
  match mode with
  | Web.Binary -> Ok body
  | Web.Text -> Web.Base64.decode body

let decode_messages ~codec ~max_size frames =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | Web.Message frame :: rest ->
        (match Grpc_core.Message.decode ~max_size ~codec frame with
         | Ok msg -> loop (msg :: acc) rest
         | Error e ->
             Error Grpc_core.Status.{
               code = Internal;
               message = Printf.sprintf "Decode error: %s" e;
               details = None;
             })
    | Web.Trailers _ :: rest ->
        loop acc rest
  in
  loop [] frames

let send_unary_response ~flow ~cors ~mode ~encodings ~resp_body ~trailers ~codec =
  let trailers = if List.mem_assoc "grpc-status" trailers then trailers
    else ("grpc-status", "0") :: trailers
  in
  let trailer_frame = Web.encode_frame (Web.Trailers trailers) in
  let body_bin = resp_body ^ trailer_frame in
  let body =
    match mode with
    | Web.Binary -> body_bin
    | Web.Text -> Web.Base64.encode body_bin
  in
  let headers = grpc_web_headers ~cors ~mode ~encodings ~codec in
  let headers = ("content-length", string_of_int (String.length body)) :: headers in
  send_plain ~flow ~status:200 ~reason:"OK" ~headers ~body

let send_streaming_response ~flow ~clock ~timeout ~cors ~mode ~encodings ~codec ~response_stream =
  let headers = grpc_web_headers ~cors ~mode ~encodings ~codec in
  let headers = ("transfer-encoding", "chunked") :: headers in
  Http1.write_response_headers flow ~status:200 ~reason:"OK" ~headers;
  let encoder_state = ref Web.Base64.Stream.enc_init in

  let deadline = Option.map (fun t -> Eio.Time.now clock +. t) timeout in
  let deadline_exceeded () =
    match deadline with
    | None -> false
    | Some d -> Eio.Time.now clock >= d
  in

  let send_frame frame =
    match mode with
    | Web.Binary ->
        Http1.write_chunk flow frame
    | Web.Text ->
        let encoded, st = Web.Base64.Stream.encode_chunk !encoder_state frame in
        encoder_state := st;
        Http1.write_chunk flow encoded
  in

  let error_status = ref None in

  let rec write_messages () =
    if deadline_exceeded () then
      error_status := Some deadline_status
    else
      let next =
        match deadline with
        | None ->
            (try Some (Grpc_stream.take response_stream) with End_of_file -> None)
        | Some d ->
            let remaining = d -. Eio.Time.now clock in
            if remaining <= 0.0 then (
              error_status := Some deadline_status;
              None
            ) else
              (try
                 Some (Eio.Time.with_timeout_exn clock remaining (fun () ->
                   Grpc_stream.take response_stream))
               with
               | End_of_file -> None
               | Eio.Time.Timeout ->
                   error_status := Some deadline_status;
                   None)
      in
      match next with
      | None -> ()
      | Some msg ->
          (match Grpc_core.Message.encode ~codec msg with
           | Error e ->
               error_status := Some Grpc_core.Status.{
                 code = Internal;
                 message = e;
                 details = None;
               }
           | Ok frame ->
               send_frame frame;
               write_messages ())
  in

  write_messages ();

  let trailers = match !error_status with
    | None -> [("grpc-status", "0")]
    | Some status -> grpc_status_trailers status
  in
  let trailer_frame = Web.encode_frame (Web.Trailers trailers) in
  send_frame trailer_frame;
  (match mode with
   | Web.Binary -> ()
   | Web.Text ->
       let final = Web.Base64.Stream.encode_final !encoder_state in
       Http1.write_chunk flow final);
  Http1.finish_chunked flow

let handle_grpc_web ~sw:_ ~clock ~server ~config ~flow (req : Http1.request) =
  let encodings = supported_encodings server in
  let content_type = Http1.header_value req.headers "content-type" |> Option.value ~default:"" in
  match Web.mode_of_content_type content_type with
  | Error _ ->
      let headers = cors_headers config.cors in
      let headers = ("content-length", "0") :: headers in
      send_plain ~flow ~status:415 ~reason:"Unsupported Media Type"
        ~headers ~body:""
  | Ok mode ->
      match Server.lookup_method server req.target with
      | Error status ->
          send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status
      | Ok (_service, method_def, _) ->
          let metadata = req.headers in
          match request_codec_of_metadata server metadata, response_codec_of_metadata server metadata with
          | Error status, _ | _, Error status ->
              send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status
          | Ok request_codec, Ok response_codec ->
              let raw_body =
                match decode_request_frames ~mode ~body:req.body with
                | Ok b -> Ok b
                | Error e ->
                    Error Grpc_core.Status.{ code = Invalid_argument; message = e; details = None }
              in
              (match raw_body with
               | Error status ->
                   send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status
               | Ok body_bin ->
                   match Web.decode_frames_complete body_bin with
                   | Error e ->
                       let status = Grpc_core.Status.{ code = Invalid_argument; message = e; details = None } in
                       send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status
                   | Ok frames ->
                       let max_size = (Server.config server).max_message_size in
                       match method_def.Service.method_type with
                       | Service.Unary ->
                           (match decode_messages ~codec:request_codec ~max_size frames with
                            | Error status ->
                                send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status
                            | Ok [request_data] ->
                                let result =
                                  Server.handle_decoded_request server ~clock
                                    ~path:req.target ~metadata ~request_data
                                    ~response_codec ~method_def
                                in
                                (match result with
                                 | Ok (resp_body, trailers, resp_codec) ->
                                     send_unary_response ~flow ~cors:config.cors ~mode ~encodings
                                       ~resp_body ~trailers ~codec:resp_codec
                                 | Error status ->
                                     send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status)
                            | Ok _ ->
                                let status = Grpc_core.Status.{
                                  code = Invalid_argument;
                                  message = "Unary request must contain exactly one message";
                                  details = None;
                                } in
                                send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status)
                       | Service.ServerStreaming ->
                           (match decode_messages ~codec:request_codec ~max_size frames with
                            | Error status ->
                                send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status
                            | Ok [request_data] ->
                                (match method_def.handler with
                                 | `ServerStreaming handler ->
                                     let response_stream = handler request_data in
                                     let timeout_seconds =
                                       timeout_seconds_of_metadata server metadata
                                     in
                                     send_streaming_response ~flow ~clock ~timeout:timeout_seconds
                                       ~cors:config.cors ~mode ~encodings ~codec:response_codec
                                       ~response_stream
                                 | _ ->
                                     let status = Grpc_core.Status.{
                                       code = Internal;
                                       message = "Handler type mismatch";
                                       details = None;
                                     } in
                                     send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status)
                            | Ok _ ->
                                let status = Grpc_core.Status.{
                                  code = Invalid_argument;
                                  message = "Server streaming request must contain exactly one message";
                                  details = None;
                                } in
                                send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status)
                       | Service.ClientStreaming ->
                           (match decode_messages ~codec:request_codec ~max_size frames with
                            | Error status ->
                                send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status
                            | Ok messages ->
                                (match method_def.handler with
                                 | `ClientStreaming handler ->
                                     let request_stream = Grpc_stream.create 16 in
                                     List.iter (fun msg -> Grpc_stream.add request_stream msg) messages;
                                     Grpc_stream.close request_stream;
                                     let timeout_seconds = timeout_seconds_of_metadata server metadata in
                                     let response =
                                       match timeout_seconds with
                                       | None -> Ok (handler request_stream)
                                       | Some secs ->
                                           (try Ok (Eio.Time.with_timeout_exn clock secs (fun () ->
                                              handler request_stream))
                                            with Eio.Time.Timeout -> Error deadline_status)
                                     in
                                     (match response with
                                      | Ok resp_body ->
                                          send_unary_response ~flow ~cors:config.cors ~mode ~encodings
                                            ~resp_body ~trailers:[] ~codec:response_codec
                                      | Error status ->
                                          send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status)
                                 | _ ->
                                     let status = Grpc_core.Status.{
                                       code = Internal;
                                       message = "Handler type mismatch";
                                       details = None;
                                     } in
                                     send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status))
                       | Service.BidiStreaming ->
                           (match decode_messages ~codec:request_codec ~max_size frames with
                            | Error status ->
                                send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status
                            | Ok messages ->
                                (match method_def.handler with
                                 | `Bidi handler ->
                                     let request_stream = Grpc_stream.create 16 in
                                     List.iter (fun msg -> Grpc_stream.add request_stream msg) messages;
                                     Grpc_stream.close request_stream;
                                     let response_stream = handler request_stream in
                                     let timeout_seconds = timeout_seconds_of_metadata server metadata in
                                     send_streaming_response ~flow ~clock ~timeout:timeout_seconds
                                       ~cors:config.cors ~mode ~encodings ~codec:response_codec
                                       ~response_stream
                                 | _ ->
                                     let status = Grpc_core.Status.{
                                       code = Internal;
                                       message = "Handler type mismatch";
                                       details = None;
                                     } in
                                     send_grpc_web_error ~flow ~cors:config.cors ~mode ~encodings status))
              )

let serve ?config ~sw ~env (server : Server.t) =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let config = Option.value ~default:(default_config server) config in

  let tls_server_config = match config.tls with
    | Some tls ->
        let cfg = Tls_config.load_http1 tls in
        Eio.traceln "🔒 gRPC-Web TLS enabled (ALPN: http/1.1)";
        Some cfg
    | None -> None
  in

  let socket = Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true config.addr in
  Eio.traceln "gRPC-Web server on %a" Eio.Net.Sockaddr.pp config.addr;

  let handle_connection flow _addr =
    try
      let reader = Eio.Buf_read.of_flow ~max_size:config.max_request_body flow in
      let req = Http1.read_request reader ~max_header_size:16384 ~max_body_size:config.max_request_body in
      match String.uppercase_ascii req.meth with
      | "OPTIONS" ->
          let headers = preflight_headers config.cors in
          let headers = ("content-length", "0") :: headers in
          send_plain ~flow ~status:204 ~reason:"No Content" ~headers ~body:""
      | "POST" ->
          handle_grpc_web ~sw ~clock ~server ~config ~flow req
      | _ ->
          let headers = cors_headers config.cors in
          let headers = ("content-length", "0") :: headers in
          send_plain ~flow ~status:405 ~reason:"Method Not Allowed"
            ~headers ~body:""
    with
    | End_of_file -> ()
    | Failure msg ->
        let headers = cors_headers config.cors in
        let headers = ("content-length", "0") :: headers in
        send_plain ~flow ~status:400 ~reason:"Bad Request"
          ~headers ~body:"";
        Eio.traceln "gRPC-Web parse error: %s" msg
    | exn ->
        let headers = cors_headers config.cors in
        let headers = ("content-length", "0") :: headers in
        send_plain ~flow ~status:500 ~reason:"Internal Server Error"
          ~headers ~body:"";
        Eio.traceln "gRPC-Web error: %s" (Printexc.to_string exn)
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
    Eio.Net.accept_fork socket ~sw
      ~on_error:(fun exn -> Eio.traceln "gRPC-Web connection error: %s" (Printexc.to_string exn))
      accept_tls
  done
