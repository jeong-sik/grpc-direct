(** gRPC-Web client over HTTP/1.1. *)

module Http1 = Grpc_web_http1
module Web = Grpc_web

type tls_config =
  { ca_file : string option
  ; cert_file : string option
  ; key_file : string option
  ; verify_peer : bool
  }

let tls_insecure () : tls_config =
  { ca_file = None; cert_file = None; key_file = None; verify_peer = false }
;;

let tls_with_ca ~ca_file : tls_config =
  { ca_file = Some ca_file; cert_file = None; key_file = None; verify_peer = true }
;;

let tls_mtls ~ca_file ~cert_file ~key_file : tls_config =
  { ca_file = Some ca_file
  ; cert_file = Some cert_file
  ; key_file = Some key_file
  ; verify_peer = true
  }
;;

type config =
  { target : string
  ; mode : Web.mode
  ; codec : Grpc_core.Codec.t
  ; timeout : float option
  ; metadata : (string * string) list
  ; tls : tls_config option
  }

type t =
  { config : config
  ; scheme : string
  ; host : string
  ; port : int
  ; tls_client_config : Tls.Config.client option
  ; mutable closed : bool
  }

let default_config ~target =
  { target
  ; mode = Web.Binary
  ; codec = Grpc_core.Codec.identity
  ; timeout = None
  ; metadata = []
  ; tls = None
  }
;;

let parse_target (target : string) =
  try
    let uri = Uri.of_string target in
    let scheme = Uri.scheme uri |> Option.value ~default:"http" in
    let host = Uri.host uri |> Option.value ~default:"localhost" in
    let port =
      Uri.port uri |> Option.value ~default:(if scheme = "https" then 443 else 80)
    in
    Some (scheme, host, port)
  with
  | _ -> None
;;

let read_file = File_util.read_file

let build_tls_client_config ~host (tls_cfg : tls_config option)
  : (Tls.Config.client option, string) result
  =
  let authenticator =
    match tls_cfg with
    | Some { verify_peer = false; _ } ->
      let time () = Some (Ptime_clock.now ()) in
      ignore time;
      Ok (fun ?ip:_ ~host:_ _certs -> Ok None)
    | Some { ca_file = Some ca_file; _ } ->
      let ca_pem = read_file ca_file in
      (match X509.Certificate.decode_pem_multiple ca_pem with
       | Error (`Msg msg) -> Error ("CA certificate error: " ^ msg)
       | Ok ca_certs ->
         let time () = Some (Ptime_clock.now ()) in
         Ok (X509.Authenticator.chain_of_trust ~time ca_certs))
    | _ ->
      (match Ca_certs.authenticator () with
       | Ok auth -> Ok auth
       | Error (`Msg msg) -> Error ("CA certificate error: " ^ msg))
  in
  match authenticator with
  | Error _ as e -> e
  | Ok authenticator ->
    let certificates =
      match tls_cfg with
      | Some { cert_file = Some cert_file; key_file = Some key_file; _ } ->
        let cert_pem = read_file cert_file in
        let key_pem = read_file key_file in
        (match
           ( X509.Certificate.decode_pem_multiple cert_pem
           , X509.Private_key.decode_pem key_pem )
         with
         | Ok certs, Ok key -> Some (`Single (certs, key))
         | _ -> None)
      | _ -> None
    in
    (match
       Tls.Config.client
         ~authenticator
         ?certificates
         ~alpn_protocols:[ "http/1.1" ]
         ~peer_name:(Domain_name.of_string_exn host |> Domain_name.host_exn)
         ()
     with
     | Ok cfg -> Ok (Some cfg)
     | Error (`Msg msg) -> Error ("TLS config error: " ^ msg))
;;

let connect ?config ~env:_ (target : string) : (t, Grpc_core.Status.t) result =
  let config = Option.value ~default:(default_config ~target) config in
  match parse_target config.target with
  | None ->
    Error
      Grpc_core.Status.
        { code = Invalid_argument
        ; message = Printf.sprintf "Invalid target URI: %s" config.target
        ; details = None
        }
  | Some (scheme, host, port) ->
    if scheme = "https"
    then (
      match build_tls_client_config ~host config.tls with
      | Error msg ->
        Error Grpc_core.Status.{ code = Internal; message = msg; details = None }
      | Ok tls_client_config ->
        Ok { config; scheme; host; port; tls_client_config; closed = false })
    else Ok { config; scheme; host; port; tls_client_config = None; closed = false }
;;

let supported_codecs (client : t) =
  if Grpc_core.Codec.is_identity client.config.codec
  then [ Grpc_core.Codec.identity ]
  else [ Grpc_core.Codec.identity; client.config.codec ]
;;

let connect_flow ~sw ~net (client : t)
  : (Eio.Flow.two_way_ty Eio.Std.r, Grpc_core.Status.t) result
  =
  let service = string_of_int client.port in
  let addrs = Eio.Net.getaddrinfo_stream net ~service client.host in
  match addrs with
  | [] ->
    Error
      Grpc_core.Status.
        { code = Unavailable
        ; message = Printf.sprintf "Cannot resolve: %s:%d" client.host client.port
        ; details = None
        }
  | addr :: _ ->
    let socket = Eio.Net.connect ~sw net addr in
    (match client.scheme with
     | "https" ->
       (match client.tls_client_config with
        | Some cfg ->
          Ok (Tls_eio.client_of_flow cfg socket :> Eio.Flow.two_way_ty Eio.Std.r)
        | None ->
          Error
            Grpc_core.Status.
              { code = Internal
              ; message = "TLS config missing for https"
              ; details = None
              })
     | _ -> Ok (socket :> Eio.Flow.two_way_ty Eio.Std.r))
;;

let header_list_to_status (trailers : (string * string) list) =
  let code =
    match List.assoc_opt "grpc-status" trailers with
    | None -> 0
    | Some s -> int_of_string s
  in
  let message =
    match List.assoc_opt "grpc-message" trailers with
    | None -> ""
    | Some s ->
      (match Web.percent_decode s with
       | Ok v -> v
       | Error _ -> s)
  in
  Grpc_core.Status.{ code = Grpc_core.Status.code_of_int code; message; details = None }
;;

let decode_response_message ~codec frames =
  let msgs =
    List.filter_map
      (function
        | Web.Message frame -> Some frame
        | Web.Trailers _ -> None)
      frames
  in
  match msgs with
  | [ frame ] ->
    (match Grpc_core.Message.decode ~codec frame with
     | Ok msg -> Ok msg
     | Error e -> Error Grpc_core.Status.{ code = Internal; message = e; details = None })
  | _ ->
    Error
      Grpc_core.Status.
        { code = Invalid_argument
        ; message = "Unary response must contain exactly one message"
        ; details = None
        }
;;

let collect_request_frames ~codec (requests : string Grpc_stream.t) =
  let buffer = Buffer.create 256 in
  let rec loop () =
    match Grpc_stream.take requests with
    | msg ->
      (match Grpc_core.Message.encode ~codec msg with
       | Ok framed ->
         Buffer.add_string buffer framed;
         loop ()
       | Error e ->
         Error Grpc_core.Status.{ code = Internal; message = e; details = None })
    | exception End_of_file -> Ok (Buffer.contents buffer)
  in
  loop ()
;;

let call_unary
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(request : string)
  =
  if client.closed
  then
    Error
      Grpc_core.Status.
        { code = Failed_precondition; message = "Client is closed"; details = None }
  else (
    let net = Eio.Stdenv.net env in
    let path = Printf.sprintf "/%s/%s" service method_ in
    let codec = client.config.codec in
    match Grpc_core.Message.encode ~codec request with
    | Error e -> Error Grpc_core.Status.{ code = Internal; message = e; details = None }
    | Ok framed_request ->
      let body_bin = framed_request in
      let body =
        match client.config.mode with
        | Web.Binary -> body_bin
        | Web.Text -> Web.Base64.encode body_bin
      in
      let accept_enc =
        if Grpc_core.Codec.is_identity codec
        then "identity"
        else codec.Grpc_core.Codec.name ^ ", identity"
      in
      let headers =
        [ "host", Printf.sprintf "%s:%d" client.host client.port
        ; "content-type", Web.content_type client.config.mode
        ; "x-grpc-web", "1"
        ; "grpc-accept-encoding", accept_enc
        ; "content-length", string_of_int (String.length body)
        ; "connection", "close"
        ]
      in
      let headers =
        if Grpc_core.Codec.is_identity codec
        then headers
        else ("grpc-encoding", codec.Grpc_core.Codec.name) :: headers
      in
      let headers =
        match deadline with
        | Some d ->
          let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float d) in
          ("grpc-timeout", Grpc_core.Timeout.to_string timeout_ns) :: headers
        | None ->
          (match client.config.timeout with
           | None -> headers
           | Some secs ->
             let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float secs) in
             ("grpc-timeout", Grpc_core.Timeout.to_string timeout_ns) :: headers)
      in
      let headers = client.config.metadata @ headers in
      (match connect_flow ~sw ~net client with
       | Error _ as e -> e
       | Ok flow ->
         Http1.write_request flow ~meth:"POST" ~target:path ~headers ~body;
         let reader = Eio.Buf_read.of_flow ~max_size:(8 * 1024 * 1024) flow in
         let resp =
           Http1.read_response
             reader
             ~max_header_size:16384
             ~max_body_size:(64 * 1024 * 1024)
         in
         if resp.status_code <> 200
         then
           Error
             Grpc_core.Status.{ code = Unknown; message = "HTTP error"; details = None }
         else (
           let mode =
             match Http1.header_value resp.headers "content-type" with
             | Some ct ->
               (match Web.mode_of_content_type ct with
                | Ok m -> m
                | Error _ -> client.config.mode)
             | None -> client.config.mode
           in
           let body_bin =
             match mode with
             | Web.Binary -> Ok resp.body
             | Web.Text -> Web.Base64.decode resp.body
           in
           match body_bin with
           | Error e ->
             Error
               Grpc_core.Status.{ code = Invalid_argument; message = e; details = None }
           | Ok body ->
             (match Web.decode_frames_complete body with
              | Error e ->
                Error
                  Grpc_core.Status.
                    { code = Invalid_argument; message = e; details = None }
              | Ok frames ->
                let trailers =
                  frames
                  |> List.filter_map (function
                    | Web.Trailers t -> Some t
                    | _ -> None)
                  |> List.concat
                in
                let status = header_list_to_status trailers in
                if not (Grpc_core.Status.is_ok status)
                then Error status
                else (
                  let resp_codec =
                    match Http1.header_value resp.headers "grpc-encoding" with
                    | None -> Grpc_core.Codec.identity
                    | Some enc ->
                      (match
                         Grpc_core.Codec.find_by_name
                           ~supported:(supported_codecs client)
                           enc
                       with
                       | Some c -> c
                       | None -> Grpc_core.Codec.identity)
                  in
                  decode_response_message ~codec:resp_codec frames)))))
;;

let call_server_streaming
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(request : string)
  =
  let stream = Grpc_stream.create 16 in
  Eio.Fiber.fork ~sw (fun () ->
    let net = Eio.Stdenv.net env in
    let path = Printf.sprintf "/%s/%s" service method_ in
    let codec = client.config.codec in
    let framed_request =
      match Grpc_core.Message.encode ~codec request with
      | Ok f -> f
      | Error e ->
        Grpc_stream.add
          stream
          (Error Grpc_core.Status.{ code = Internal; message = e; details = None });
        Grpc_stream.close stream;
        raise Exit
    in
    let body_bin = framed_request in
    let body =
      match client.config.mode with
      | Web.Binary -> body_bin
      | Web.Text -> Web.Base64.encode body_bin
    in
    let accept_enc =
      if Grpc_core.Codec.is_identity codec
      then "identity"
      else codec.Grpc_core.Codec.name ^ ", identity"
    in
    let headers =
      [ "host", Printf.sprintf "%s:%d" client.host client.port
      ; "content-type", Web.content_type client.config.mode
      ; "x-grpc-web", "1"
      ; "grpc-accept-encoding", accept_enc
      ; "content-length", string_of_int (String.length body)
      ; "connection", "close"
      ]
    in
    let headers =
      if Grpc_core.Codec.is_identity codec
      then headers
      else ("grpc-encoding", codec.Grpc_core.Codec.name) :: headers
    in
    let headers =
      match deadline with
      | Some d ->
        let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float d) in
        ("grpc-timeout", Grpc_core.Timeout.to_string timeout_ns) :: headers
      | None ->
        (match client.config.timeout with
         | None -> headers
         | Some secs ->
           let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float secs) in
           ("grpc-timeout", Grpc_core.Timeout.to_string timeout_ns) :: headers)
    in
    let headers = client.config.metadata @ headers in
    match connect_flow ~sw ~net client with
    | Error status ->
      Grpc_stream.add stream (Error status);
      Grpc_stream.close stream;
      raise Exit
    | Ok flow ->
      Http1.write_request flow ~meth:"POST" ~target:path ~headers ~body;
      let reader = Eio.Buf_read.of_flow ~max_size:(8 * 1024 * 1024) flow in
      let _ver, status_code, _reason, headers =
        Http1.read_response_head reader ~max_header_size:16384
      in
      if status_code <> 200
      then (
        Grpc_stream.add
          stream
          (Error
             Grpc_core.Status.{ code = Unknown; message = "HTTP error"; details = None });
        Grpc_stream.close stream;
        raise Exit);
      let resp_mode =
        match Http1.header_value headers "content-type" with
        | Some ct ->
          (match Web.mode_of_content_type ct with
           | Ok m -> m
           | Error _ -> client.config.mode)
        | None -> client.config.mode
      in
      let resp_codec =
        match Http1.header_value headers "grpc-encoding" with
        | None -> Grpc_core.Codec.identity
        | Some enc ->
          (match
             Grpc_core.Codec.find_by_name ~supported:(supported_codecs client) enc
           with
           | Some c -> c
           | None -> Grpc_core.Codec.identity)
      in
      let base64_state = ref Web.Base64.Stream.dec_init in
      let buffer = ref "" in
      let done_stream = ref false in
      let handle_frames frames =
        if !done_stream
        then ()
        else
          List.iter
            (function
              | Web.Message frame ->
                (match Grpc_core.Message.decode ~codec:resp_codec frame with
                 | Ok msg -> Grpc_stream.add stream (Ok msg)
                 | Error e ->
                   Grpc_stream.add
                     stream
                     (Error
                        Grpc_core.Status.{ code = Internal; message = e; details = None });
                   done_stream := true;
                   Grpc_stream.close stream)
              | Web.Trailers trailers ->
                let status = header_list_to_status trailers in
                Grpc_stream.add stream (Error status);
                done_stream := true;
                Grpc_stream.close stream)
            frames
      in
      let handle_binary chunk =
        if !done_stream then () else buffer := !buffer ^ chunk;
        match Web.decode_frames_partial !buffer with
        | Error e ->
          Grpc_stream.add
            stream
            (Error
               Grpc_core.Status.{ code = Invalid_argument; message = e; details = None });
          done_stream := true;
          Grpc_stream.close stream
        | Ok (frames, remaining) ->
          buffer := remaining;
          handle_frames frames
      in
      let handle_chunk chunk =
        if !done_stream
        then ()
        else (
          match resp_mode with
          | Web.Binary -> handle_binary chunk
          | Web.Text ->
            (match Web.Base64.Stream.decode_chunk !base64_state chunk with
             | Error e ->
               Grpc_stream.add
                 stream
                 (Error
                    Grpc_core.Status.
                      { code = Invalid_argument; message = e; details = None });
               done_stream := true;
               Grpc_stream.close stream
             | Ok (decoded, st) ->
               base64_state := st;
               handle_binary decoded))
      in
      Http1.read_body_chunks
        reader
        ~max_body_size:(64 * 1024 * 1024)
        headers
        ~on_chunk:handle_chunk;
      (match resp_mode with
       | Web.Binary -> ()
       | Web.Text ->
         (match Web.Base64.Stream.decode_final !base64_state with
          | Ok _ -> ()
          | Error e ->
            Grpc_stream.add
              stream
              (Error
                 Grpc_core.Status.{ code = Invalid_argument; message = e; details = None });
            done_stream := true;
            Grpc_stream.close stream));
      if not !done_stream
      then (
        Grpc_stream.add stream (Error Grpc_core.Status.ok);
        Grpc_stream.close stream));
  stream
;;

let call_client_streaming
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(requests : string Grpc_stream.t)
  =
  if client.closed
  then
    Error
      Grpc_core.Status.
        { code = Failed_precondition; message = "Client is closed"; details = None }
  else (
    let net = Eio.Stdenv.net env in
    let path = Printf.sprintf "/%s/%s" service method_ in
    let codec = client.config.codec in
    match collect_request_frames ~codec requests with
    | Error status -> Error status
    | Ok body_bin ->
      let body =
        match client.config.mode with
        | Web.Binary -> body_bin
        | Web.Text -> Web.Base64.encode body_bin
      in
      let accept_enc =
        if Grpc_core.Codec.is_identity codec
        then "identity"
        else codec.Grpc_core.Codec.name ^ ", identity"
      in
      let headers =
        [ "host", Printf.sprintf "%s:%d" client.host client.port
        ; "content-type", Web.content_type client.config.mode
        ; "x-grpc-web", "1"
        ; "grpc-accept-encoding", accept_enc
        ; "content-length", string_of_int (String.length body)
        ; "connection", "close"
        ]
      in
      let headers =
        if Grpc_core.Codec.is_identity codec
        then headers
        else ("grpc-encoding", codec.Grpc_core.Codec.name) :: headers
      in
      let headers =
        match deadline with
        | Some d ->
          let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float d) in
          ("grpc-timeout", Grpc_core.Timeout.to_string timeout_ns) :: headers
        | None ->
          (match client.config.timeout with
           | None -> headers
           | Some secs ->
             let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float secs) in
             ("grpc-timeout", Grpc_core.Timeout.to_string timeout_ns) :: headers)
      in
      let headers = client.config.metadata @ headers in
      (match connect_flow ~sw ~net client with
       | Error _ as e -> e
       | Ok flow ->
         Http1.write_request flow ~meth:"POST" ~target:path ~headers ~body;
         let reader = Eio.Buf_read.of_flow ~max_size:(8 * 1024 * 1024) flow in
         let resp =
           Http1.read_response
             reader
             ~max_header_size:16384
             ~max_body_size:(64 * 1024 * 1024)
         in
         if resp.status_code <> 200
         then
           Error
             Grpc_core.Status.{ code = Unknown; message = "HTTP error"; details = None }
         else (
           let mode =
             match Http1.header_value resp.headers "content-type" with
             | Some ct ->
               (match Web.mode_of_content_type ct with
                | Ok m -> m
                | Error _ -> client.config.mode)
             | None -> client.config.mode
           in
           let body_bin =
             match mode with
             | Web.Binary -> Ok resp.body
             | Web.Text -> Web.Base64.decode resp.body
           in
           match body_bin with
           | Error e ->
             Error
               Grpc_core.Status.{ code = Invalid_argument; message = e; details = None }
           | Ok body ->
             (match Web.decode_frames_complete body with
              | Error e ->
                Error
                  Grpc_core.Status.
                    { code = Invalid_argument; message = e; details = None }
              | Ok frames ->
                let trailers =
                  frames
                  |> List.filter_map (function
                    | Web.Trailers t -> Some t
                    | _ -> None)
                  |> List.concat
                in
                let status = header_list_to_status trailers in
                if not (Grpc_core.Status.is_ok status)
                then Error status
                else (
                  let resp_codec =
                    match Http1.header_value resp.headers "grpc-encoding" with
                    | None -> Grpc_core.Codec.identity
                    | Some enc ->
                      (match
                         Grpc_core.Codec.find_by_name
                           ~supported:(supported_codecs client)
                           enc
                       with
                       | Some c -> c
                       | None -> Grpc_core.Codec.identity)
                  in
                  decode_response_message ~codec:resp_codec frames)))))
;;

let call_bidi
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(requests : string Grpc_stream.t)
  =
  let stream = Grpc_stream.create 16 in
  Eio.Fiber.fork ~sw (fun () ->
    let net = Eio.Stdenv.net env in
    let path = Printf.sprintf "/%s/%s" service method_ in
    let codec = client.config.codec in
    match collect_request_frames ~codec requests with
    | Error status ->
      Grpc_stream.add stream (Error status);
      Grpc_stream.close stream
    | Ok body_bin ->
      let body =
        match client.config.mode with
        | Web.Binary -> body_bin
        | Web.Text -> Web.Base64.encode body_bin
      in
      let accept_enc =
        if Grpc_core.Codec.is_identity codec
        then "identity"
        else codec.Grpc_core.Codec.name ^ ", identity"
      in
      let headers =
        [ "host", Printf.sprintf "%s:%d" client.host client.port
        ; "content-type", Web.content_type client.config.mode
        ; "x-grpc-web", "1"
        ; "grpc-accept-encoding", accept_enc
        ; "content-length", string_of_int (String.length body)
        ; "connection", "close"
        ]
      in
      let headers =
        if Grpc_core.Codec.is_identity codec
        then headers
        else ("grpc-encoding", codec.Grpc_core.Codec.name) :: headers
      in
      let headers =
        match deadline with
        | Some d ->
          let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float d) in
          ("grpc-timeout", Grpc_core.Timeout.to_string timeout_ns) :: headers
        | None ->
          (match client.config.timeout with
           | None -> headers
           | Some secs ->
             let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float secs) in
             ("grpc-timeout", Grpc_core.Timeout.to_string timeout_ns) :: headers)
      in
      let headers = client.config.metadata @ headers in
      (match connect_flow ~sw ~net client with
       | Error status ->
         Grpc_stream.add stream (Error status);
         Grpc_stream.close stream;
         raise Exit
       | Ok flow ->
         Http1.write_request flow ~meth:"POST" ~target:path ~headers ~body;
         let reader = Eio.Buf_read.of_flow ~max_size:(8 * 1024 * 1024) flow in
         let _ver, status_code, _reason, headers =
           Http1.read_response_head reader ~max_header_size:16384
         in
         if status_code <> 200
         then (
           Grpc_stream.add
             stream
             (Error
                Grpc_core.Status.
                  { code = Unknown; message = "HTTP error"; details = None });
           Grpc_stream.close stream;
           raise Exit);
         let resp_mode =
           match Http1.header_value headers "content-type" with
           | Some ct ->
             (match Web.mode_of_content_type ct with
              | Ok m -> m
              | Error _ -> client.config.mode)
           | None -> client.config.mode
         in
         let resp_codec =
           match Http1.header_value headers "grpc-encoding" with
           | None -> Grpc_core.Codec.identity
           | Some enc ->
             (match
                Grpc_core.Codec.find_by_name ~supported:(supported_codecs client) enc
              with
              | Some c -> c
              | None -> Grpc_core.Codec.identity)
         in
         let base64_state = ref Web.Base64.Stream.dec_init in
         let buffer = ref "" in
         let done_stream = ref false in
         let handle_frames frames =
           if !done_stream
           then ()
           else
             List.iter
               (function
                 | Web.Message frame ->
                   (match Grpc_core.Message.decode ~codec:resp_codec frame with
                    | Ok msg -> Grpc_stream.add stream (Ok msg)
                    | Error e ->
                      Grpc_stream.add
                        stream
                        (Error
                           Grpc_core.Status.
                             { code = Internal; message = e; details = None });
                      done_stream := true;
                      Grpc_stream.close stream)
                 | Web.Trailers trailers ->
                   let status = header_list_to_status trailers in
                   Grpc_stream.add stream (Error status);
                   done_stream := true;
                   Grpc_stream.close stream)
               frames
         in
         let handle_binary chunk =
           if !done_stream then () else buffer := !buffer ^ chunk;
           match Web.decode_frames_partial !buffer with
           | Error e ->
             Grpc_stream.add
               stream
               (Error
                  Grpc_core.Status.
                    { code = Invalid_argument; message = e; details = None });
             done_stream := true;
             Grpc_stream.close stream
           | Ok (frames, remaining) ->
             buffer := remaining;
             handle_frames frames
         in
         let handle_chunk chunk =
           if !done_stream
           then ()
           else (
             match resp_mode with
             | Web.Binary -> handle_binary chunk
             | Web.Text ->
               (match Web.Base64.Stream.decode_chunk !base64_state chunk with
                | Error e ->
                  Grpc_stream.add
                    stream
                    (Error
                       Grpc_core.Status.
                         { code = Invalid_argument; message = e; details = None });
                  done_stream := true;
                  Grpc_stream.close stream
                | Ok (decoded, st) ->
                  base64_state := st;
                  handle_binary decoded))
         in
         Http1.read_body_chunks
           reader
           ~max_body_size:(64 * 1024 * 1024)
           headers
           ~on_chunk:handle_chunk;
         (match resp_mode with
          | Web.Binary -> ()
          | Web.Text ->
            (match Web.Base64.Stream.decode_final !base64_state with
             | Ok _ -> ()
             | Error e ->
               Grpc_stream.add
                 stream
                 (Error
                    Grpc_core.Status.
                      { code = Invalid_argument; message = e; details = None });
               done_stream := true;
               Grpc_stream.close stream));
         if not !done_stream
         then (
           Grpc_stream.add stream (Error Grpc_core.Status.ok);
           Grpc_stream.close stream)));
  stream
;;

let close (client : t) = client.closed <- true
