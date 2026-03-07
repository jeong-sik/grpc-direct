(** gRPC Server using Eio and h2.

    {b Thread Safety:}
    - Single-domain safe: Yes
    - Multi-domain safe: Partial
      - Services Hashtbl: Safe if registered at startup only (before [serve])
      - [mutable running]: Simple flag, atomic read/write on most platforms
      - Request body [ref]: Per-request, no sharing between fibers

    @see {{: https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md } Eio Multicore Guide}

    Example:
    {[
      let server = Server.create ()
        |> Server.add_service greeter
        |> Server.with_interceptor (Interceptor.logging ())
      in
      Server.serve ~sw ~env server
    ]} *)

(** Server configuration *)
type config =
  { host : string
  ; port : int
  ; codecs : Grpc_core.Codec.t list
  ; max_message_size : int
  ; default_timeout : Grpc_core.Timeout.t option
  ; tls : Tls_config.t option
  }

let default_config : config =
  { host = "127.0.0.1"
  ; port = 50051
  ; codecs = [ Grpc_core.Codec.identity ]
  ; max_message_size = 4 * 1024 * 1024
  ; default_timeout = Some Grpc_core.Timeout.default
  ; tls = None
  }
;;

(** Server state *)
type t =
  { config : config
  ; services : (string, Service.t) Hashtbl.t
  ; interceptors : string Interceptor.t list
  ; metrics : Metrics.t option
  ; mutable running : bool
  }

let supported_encodings (server : t) : string =
  server.config.codecs |> List.map (fun c -> c.Grpc_core.Codec.name) |> String.concat ", "
;;

let create ?(config = default_config) () : t =
  { config
  ; services = Hashtbl.create 16
  ; interceptors = []
  ; metrics = None
  ; running = false
  }
;;

let add_service (service : Service.t) (server : t) : t =
  Hashtbl.replace server.services service.name service;
  server
;;

let with_interceptor (interceptor : string Interceptor.t) (server : t) : t =
  { server with interceptors = server.interceptors @ [ interceptor ] }
;;

let with_metrics (metrics : Metrics.t) (server : t) : t =
  { server with metrics = Some metrics }
;;

let list_services (server : t) : string list =
  Hashtbl.fold (fun name _ acc -> name :: acc) server.services []
;;

let request_codec_of_metadata (server : t) (metadata : (string * string) list)
  : (Grpc_core.Codec.t, Grpc_core.Status.t) result
  =
  match List.assoc_opt "grpc-encoding" metadata with
  | None -> Ok Grpc_core.Codec.identity
  | Some encoding ->
    (match Grpc_core.Codec.find_by_name ~supported:server.config.codecs encoding with
     | Some codec -> Ok codec
     | None ->
       Error
         Grpc_core.Status.
           { code = Unimplemented
           ; message = Printf.sprintf "Unsupported grpc-encoding: %s" encoding
           ; details = None
           })
;;

let response_codec_of_metadata (server : t) (metadata : (string * string) list)
  : (Grpc_core.Codec.t, Grpc_core.Status.t) result
  =
  match List.assoc_opt "grpc-accept-encoding" metadata with
  | None -> Ok Grpc_core.Codec.identity
  | Some accepted ->
    let accepted_list = Grpc_core.Codec.parse_accept accepted in
    let accepted_list =
      if List.mem "identity" accepted_list
      then accepted_list
      else "identity" :: accepted_list
    in
    let supported = server.config.codecs in
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

let timeout_seconds_of_metadata (server : t) (metadata : (string * string) list)
  : float option
  =
  match List.assoc_opt "grpc-timeout" metadata with
  | None -> server.config.default_timeout |> Option.map Grpc_core.Timeout.to_seconds
  | Some header ->
    (match Grpc_core.Timeout.parse header with
     | None -> None (* Invalid format, ignore *)
     | Some timeout -> Some (Grpc_core.Timeout.to_seconds timeout))
;;

let lookup_method (server : t) (path : string)
  : (Service.t * Service.method_def * Grpc_core.Codec.t, Grpc_core.Status.t) result
  =
  match Http2_handler.parse_path path with
  | None ->
    Error
      Grpc_core.Status.
        { code = Unimplemented
        ; message =
            Printf.sprintf
              "Invalid path format: '%s'. Expected: /package.Service/Method"
              path
        ; details = None
        }
  | Some (service_name, method_name) ->
    (match Hashtbl.find_opt server.services service_name with
     | None ->
       let available = list_services server |> String.concat ", " in
       Error
         Grpc_core.Status.
           { code = Unimplemented
           ; message =
               Printf.sprintf
                 "Service '%s' not found. Available: [%s]"
                 service_name
                 available
           ; details = None
           }
     | Some service ->
       (match Service.get_method service method_name with
        | None ->
          Error
            Grpc_core.Status.
              { code = Unimplemented
              ; message =
                  Printf.sprintf
                    "Method '%s' not found in service '%s'. Check your .proto file."
                    method_name
                    service_name
              ; details = None
              }
        | Some method_def -> Ok (service, method_def, Grpc_core.Codec.identity)))
;;

(** Decode incoming request body *)
let decode_request ~codec body : (string, Grpc_core.Status.t) result =
  match Grpc_core.Message.decode ~codec body with
  | Error e ->
    let hint =
      if String.length body > 4 * 1024 * 1024
      then " Message may be too large; consider streaming RPC."
      else " Verify protobuf encoding matches your .proto schema."
    in
    Error
      Grpc_core.Status.
        { code = Internal
        ; message = Printf.sprintf "Decode error: %s.%s" e hint
        ; details = None
        }
  | Ok data -> Ok data
;;

(** Invoke handler with interceptor chain and deadline enforcement *)
let invoke_handler
      (server : t)
      ~clock
      ~path
      ~metadata
      ~response_codec
      ~method_def
      ~request_data
  : (string * (string * string) list * Grpc_core.Codec.t, Grpc_core.Status.t) result
  =
  (* Parse grpc-timeout header and compute timeout duration *)
  let timeout_seconds = timeout_seconds_of_metadata server metadata in
  let deadline = timeout_seconds |> Option.map (fun t -> Time_compat.now () +. t) in
  let ctx = Interceptor.context_with_metadata ~method_:path ~metadata ?deadline () in
  let base_handler _ctx =
    match method_def.Service.handler with
    | `Unary handler ->
      let response = handler request_data in
      (match Grpc_core.Message.encode ~codec:response_codec response with
       | Ok encoded -> Interceptor.{ value = encoded; trailers = [] }
       | Error e -> failwith e)
      (* Caught by outer exception handler *)
    | _ -> failwith "Streaming methods use streaming handler"
  in
  let chained = Interceptor.chain server.interceptors base_handler in
  (* Execute handler - returns tuple, not Result (exceptions handled by outer try) *)
  let run_handler () =
    let resp = chained ctx in
    resp.value, ("grpc-status", "0") :: resp.trailers, response_codec
  in
  try
    let result =
      match timeout_seconds with
      | None ->
        (* No timeout configured - run directly *)
        run_handler ()
      | Some timeout ->
        (* Enforce deadline using Eio's timeout mechanism.
             with_timeout_exn raises Timeout exception on deadline exceeded *)
        Eio.Time.with_timeout_exn clock timeout run_handler
    in
    Ok result
  with
  (* Timeout exception from Eio - convert to DEADLINE_EXCEEDED status *)
  | Eio.Time.Timeout ->
    let timeout_str =
      match timeout_seconds with
      | Some t -> Printf.sprintf " (timeout: %.3fs)" t
      | None -> ""
    in
    Error
      Grpc_core.Status.
        { code = Deadline_exceeded
        ; message = "Deadline exceeded" ^ timeout_str
        ; details = None
        }
  (* Fatal errors must propagate - don't catch and mask them *)
  | (Out_of_memory | Stack_overflow) as fatal -> raise fatal
  (* Application-level failures - log and return Internal *)
  | Failure msg ->
    Log.error "gRPC handler failure: %s" msg;
    Error
      Grpc_core.Status.
        { code = Internal; message = "Internal server error"; details = None }
  (* All other exceptions - log details but don't expose to client *)
  | exn ->
    Log.error
      "gRPC unexpected error: %s\n%s"
      (Printexc.to_string exn)
      (Printexc.get_backtrace ());
    Error Grpc_core.Status.{ code = Unknown; message = "Unknown error"; details = None }
;;

(** Handle unary request - orchestrates lookup, decode, and invocation *)
let handle_request
      (server : t)
      ~clock
      ~path
      ~metadata
      ~body
      ~request_codec
      ~response_codec
  : (string * (string * string) list * Grpc_core.Codec.t, Grpc_core.Status.t) result
  =
  match lookup_method server path with
  | Error status -> Error status
  | Ok (_service, method_def, _) ->
    (match decode_request ~codec:request_codec body with
     | Error status -> Error status
     | Ok request_data ->
       invoke_handler
         server
         ~clock
         ~path
         ~metadata
         ~response_codec
         ~method_def
         ~request_data)
;;

(** Handle a unary request with decoded message data. *)
let handle_decoded_request
      (server : t)
      ~clock
      ~path
      ~metadata
      ~request_data
      ~response_codec
      ~method_def
  : (string * (string * string) list * Grpc_core.Codec.t, Grpc_core.Status.t) result
  =
  invoke_handler server ~clock ~path ~metadata ~response_codec ~method_def ~request_data
;;

(** HTTP/2 request handler *)
let request_handler ~sw ~clock (server : t) reqd =
  let open H2 in
  let request = Reqd.request reqd in
  let path = request.target in
  let encodings = supported_encodings server in
  let content_type =
    Headers.get request.headers "content-type" |> Option.value ~default:""
  in
  if not (String.starts_with ~prefix:"application/grpc" content_type)
  then
    Reqd.respond_with_string
      reqd
      (Response.create `Unsupported_media_type)
      "Invalid content-type"
  else (
    match lookup_method server path with
    | Error status -> Http2_handler.send_error ~reqd ~encodings status
    | Ok (_service, method_def, _) ->
      let metadata =
        Headers.fold
          ~f:(fun k v acc -> (String.lowercase_ascii k, v) :: acc)
          ~init:[]
          request.headers
      in
      (match
         ( request_codec_of_metadata server metadata
         , response_codec_of_metadata server metadata )
       with
       | Error status, _ | _, Error status ->
         Http2_handler.send_error ~reqd ~encodings status
       | Ok request_codec, Ok response_codec ->
         (match method_def.handler with
          | `Unary _ ->
            let start_time = Time_compat.now () in
            Option.iter
              (fun m -> Metrics.record_call_start m ~method_:path)
              server.metrics;
            let body_parts = ref [] in
            let body = Reqd.request_body reqd in
            let rec read_body () =
              Body.Reader.schedule_read
                body
                ~on_eof:(fun () ->
                  let full_body = String.concat "" (List.rev !body_parts) in
                  match
                    handle_request
                      server
                      ~clock
                      ~path
                      ~metadata
                      ~body:full_body
                      ~request_codec
                      ~response_codec
                  with
                  | Ok (resp_body, trailers, resp_codec) ->
                    Option.iter
                      (fun m ->
                         Metrics.record_call_end
                           m
                           ~method_:path
                           ~latency_sec:(Time_compat.now () -. start_time)
                           ~success:true
                           ~request_size:(String.length full_body)
                           ~response_size:(String.length resp_body)
                           ())
                      server.metrics;
                    Http2_handler.send_response
                      ~reqd
                      ~encodings
                      ~codec:resp_codec
                      ~body:resp_body
                      ~trailers
                  | Error status ->
                    Option.iter
                      (fun m ->
                         Metrics.record_call_end
                           m
                           ~method_:path
                           ~latency_sec:(Time_compat.now () -. start_time)
                           ~success:false
                           ~request_size:(String.length full_body)
                           ())
                      server.metrics;
                    Http2_handler.send_error ~reqd ~encodings status)
                ~on_read:(fun bs ~off ~len ->
                  body_parts := Bigstringaf.substring bs ~off ~len :: !body_parts;
                  read_body ())
            in
            read_body ()
          | `ServerStreaming handler ->
            let body_parts = ref [] in
            let body = Reqd.request_body reqd in
            let rec read_body () =
              Body.Reader.schedule_read
                body
                ~on_eof:(fun () ->
                  let full_body = String.concat "" (List.rev !body_parts) in
                  match Grpc_core.Message.decode ~codec:request_codec full_body with
                  | Error e ->
                    Http2_handler.send_error
                      ~reqd
                      ~encodings
                      Grpc_core.Status.{ code = Internal; message = e; details = None }
                  | Ok request_data ->
                    let timeout_seconds = timeout_seconds_of_metadata server metadata in
                    Http2_handler.handle_server_streaming
                      ~sw
                      ~clock
                      ~timeout:timeout_seconds
                      ~reqd
                      ~response_codec
                      ~handler
                      ~request_data
                      ~encodings
                      ~method_:path
                      ~metrics:server.metrics)
                ~on_read:(fun bs ~off ~len ->
                  body_parts := Bigstringaf.substring bs ~off ~len :: !body_parts;
                  read_body ())
            in
            read_body ()
          | `ClientStreaming handler ->
            let timeout_seconds = timeout_seconds_of_metadata server metadata in
            Http2_handler.handle_client_streaming
              ~sw
              ~clock
              ~timeout:timeout_seconds
              ~reqd
              ~request_codec
              ~response_codec
              ~handler
              ~encodings
              ~method_:path
              ~metrics:server.metrics
          | `Bidi handler ->
            let timeout_seconds = timeout_seconds_of_metadata server metadata in
            Http2_handler.handle_bidi_streaming
              ~sw
              ~clock
              ~timeout:timeout_seconds
              ~reqd
              ~request_codec
              ~response_codec
              ~handler
              ~encodings
              ~method_:path
              ~metrics:server.metrics)))
;;

let error_handler _client_addr ?request:_ error _respond =
  let msg =
    match error with
    | `Exn exn -> Printf.sprintf "Exception: %s" (Printexc.to_string exn)
    | `Bad_request -> "Bad request"
    | `Bad_gateway -> "Bad gateway"
    | `Internal_server_error -> "Internal server error"
  in
  Eio.traceln "[H2-ERROR] %s" msg;
  Log.error "gRPC error: %s" msg
;;

(** Start serving *)
let serve ~sw ~env (server : t) : unit =
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, server.config.port) in
  (* Load TLS config if present *)
  let tls_server_config =
    match server.config.tls with
    | Some tls ->
      (* RNG initialization should be done at app level with Mirage_crypto_rng_eio.run *)
      (match Tls_config.load tls with
       | Ok config ->
         Log.info "🔒 TLS enabled (ALPN: h2)";
         Some config
       | Error msg -> failwith ("TLS configuration error: " ^ msg))
    | None ->
      Log.warn "ℹ️  Running without TLS (plaintext h2c)";
      None
  in
  Log.info "gRPC server on %s:%d" server.config.host server.config.port;
  server.running <- true;
  let socket = Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true addr in
  let h2_handler =
    H2_eio.Server.create_connection_handler
      ~request_handler:(fun _ -> request_handler ~sw ~clock server)
      ~error_handler
  in
  (* Wrap socket with TLS if configured.

     For TLS connections, we use Flow_handler which accepts any Eio.Flow.two_way,
     avoiding the need for Obj.magic type coercion.

     See: https://github.com/mirleft/ocaml-tls/issues/464 *)
  let handle_connection sock addr =
    match tls_server_config with
    | Some tls_config ->
      (* Perform TLS handshake on the accepted socket *)
      let tls_flow = Tls_eio.server_of_flow tls_config sock in
      (* Use Flow_handler for type-safe TLS handling *)
      Flow_handler.create_server_handler
        ~request_handler:(fun _ -> request_handler ~sw ~clock server)
        ~error_handler
        ~sw
        addr
        tls_flow
    | None -> h2_handler ~sw addr sock
  in
  while server.running do
    Eio.Net.accept_fork
      socket
      ~sw
      ~on_error:(fun exn -> Log.error "Connection error: %s" (Printexc.to_string exn))
      handle_connection
  done
;;

let shutdown (server : t) : unit =
  Log.info "Shutting down gRPC server...";
  server.running <- false
;;

(* Accessors for Server_multi *)
let config (server : t) = server.config
let services (server : t) = server.services
let interceptors (server : t) = server.interceptors
let metrics (server : t) = server.metrics
let running (server : t) = server.running
let set_running (server : t) v = server.running <- v
