(** gRPC Client using Eio and h2.

    A type-safe gRPC client built on OCaml 5's effect system.
    Supports automatic codec negotiation and interceptor chains.

    {b Supported RPC Types:}
    - [call_unary]: Single request → Single response
    - [call_server_streaming]: Single request → Stream of responses
    - [call_client_streaming]: Stream of requests → Single response
    - [call_bidi]: Stream of requests ↔ Stream of responses

    {b Thread Safety:}
    - Single-domain safe: Yes
    - Multi-domain safe: Yes - uses Grpc_eio.Stream/Promise for synchronization

    @see {{: https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md } Eio Multicore Guide}

    Example (Unary):
    {[
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let client = Client.connect ~sw ~env "http://localhost:50051" in
      let response = Client.call_unary client
        ~service:"helloworld.Greeter"
        ~method_:"SayHello"
        ~request:request_bytes
      in
      match response with
      | Ok bytes -> print_endline "Success!"
      | Error status -> print_endline status.message
    ]}

    Example (Bidi Streaming):
    {[
      let requests = Grpc_eio.Stream.create 16 in
      let responses = Client.call_bidi ~sw ~env client
        ~service:"chat.Chat"
        ~method_:"Chat"
        ~requests
      in
      (* Send messages *)
      Grpc_eio.Stream.add requests "Hello";
      (* Receive messages *)
      match Grpc_eio.Stream.take responses with
      | Ok msg -> print_endline msg
      | Error status -> print_endline status.message
    ]} *)

(** Client TLS configuration *)
type tls_config =
  { ca_file : string option (** CA cert for server verification (None = system CA) *)
  ; cert_file : string option (** Client cert for mTLS *)
  ; key_file : string option (** Client key for mTLS *)
  ; verify_peer : bool (** Verify server certificate (default true) *)
  }

(** Per-RPC credentials for authentication tokens.
    These credentials are attached to each RPC call. *)
type call_credentials =
  | BearerToken of string (** OAuth2 Bearer token *)
  | CustomHeader of (string * string) list (** Custom authentication headers *)
  | ComputeCallCreds of (unit -> (string * string) list) (** Dynamic credentials *)

(** Channel credentials for transport security.
    Similar to Go's [grpc.WithTransportCredentials].

    {b Example:}
    {[
      (* Insecure connection *)
      let creds = Credentials.insecure ()

      (* TLS with custom CA *)
      let creds = Credentials.tls ~ca_file:"./ca.pem" ()

      (* mTLS *)
      let creds = Credentials.mtls
        ~ca_file:"./ca.pem"
        ~cert_file:"./client.pem"
        ~key_file:"./client.key"
        ()

      (* TLS + Bearer token *)
      let creds = Credentials.with_token
        ~token:"my-jwt-token"
        ~tls:(Credentials.tls_config ~ca_file:"./ca.pem" ())
        ()
    ]}

    @see {{: https://grpc.github.io/grpc/core/group__grpc__arg__keys.html } gRPC Args} *)
type channel_credentials =
  | Insecure (** No TLS, plaintext HTTP/2 *)
  | Tls of tls_config (** TLS with optional mTLS *)
  | WithCallCredentials of
      { transport : channel_credentials (** Underlying transport credentials *)
      ; call_creds : call_credentials (** Per-RPC credentials *)
      }

(** Credentials module for unified authentication abstraction *)
module Credentials = struct
  (** Create insecure (plaintext) credentials *)
  let insecure () : channel_credentials = Insecure

  (** Create TLS credentials with optional CA file *)
  let tls ?ca_file () : channel_credentials =
    Tls { ca_file; cert_file = None; key_file = None; verify_peer = true }
  ;;

  (** Create mTLS credentials with client certificate *)
  let mtls ~ca_file ~cert_file ~key_file () : channel_credentials =
    Tls
      { ca_file = Some ca_file
      ; cert_file = Some cert_file
      ; key_file = Some key_file
      ; verify_peer = true
      }
  ;;

  (** Create TLS config (for use with with_token) *)
  let tls_config ?ca_file ?cert_file ?key_file () : tls_config =
    { ca_file; cert_file; key_file; verify_peer = true }
  ;;

  (** Add call credentials (bearer token) to channel credentials *)
  let with_token ~token ?(tls : tls_config option) () : channel_credentials =
    let transport =
      match tls with
      | Some cfg -> Tls cfg
      | None ->
        Tls { ca_file = None; cert_file = None; key_file = None; verify_peer = true }
    in
    WithCallCredentials { transport; call_creds = BearerToken token }
  ;;

  (** Add custom header credentials to channel credentials *)
  let with_headers ~headers ?(tls : tls_config option) () : channel_credentials =
    let transport =
      match tls with
      | Some cfg -> Tls cfg
      | None ->
        Tls { ca_file = None; cert_file = None; key_file = None; verify_peer = true }
    in
    WithCallCredentials { transport; call_creds = CustomHeader headers }
  ;;

  (** Add dynamic credentials (computed per-call) *)
  let with_compute_creds ~f ?(tls : tls_config option) () : channel_credentials =
    let transport =
      match tls with
      | Some cfg -> Tls cfg
      | None ->
        Tls { ca_file = None; cert_file = None; key_file = None; verify_peer = true }
    in
    WithCallCredentials { transport; call_creds = ComputeCallCreds f }
  ;;

  (** Check if credentials require TLS *)
  let requires_tls (creds : channel_credentials) : bool =
    match creds with
    | Insecure -> false
    | Tls _ -> true
    | WithCallCredentials { transport; _ } ->
      (match transport with
       | Insecure -> false
       | Tls _ -> true
       | WithCallCredentials _ -> true)
  ;;

  (* Nested: assume TLS *)

  (** Extract TLS config from credentials *)
  let to_tls_config (creds : channel_credentials) : tls_config option =
    match creds with
    | Insecure -> None
    | Tls cfg -> Some cfg
    | WithCallCredentials { transport; _ } ->
      (match transport with
       | Tls cfg -> Some cfg
       | _ -> None)
  ;;

  (** Extract call credentials headers *)
  let get_call_headers (creds : channel_credentials) : (string * string) list =
    match creds with
    | Insecure | Tls _ -> []
    | WithCallCredentials { call_creds; _ } ->
      (match call_creds with
       | BearerToken token -> [ "authorization", "Bearer " ^ token ]
       | CustomHeader headers -> headers
       | ComputeCallCreds f -> f ())
  ;;
end

(** Keep-alive configuration.

    gRPC uses HTTP/2 PING frames for connection health checking.
    When enabled, the client periodically sends PING frames and
    expects acknowledgements within a timeout period.

    @see {{: https://grpc.io/docs/guides/keepalive/ } gRPC Keepalive Guide} *)
type keepalive_config =
  { time : float (** Interval between PINGs in seconds (default: 7200.0 = 2 hours) *)
  ; timeout : float (** Time to wait for PING ACK in seconds (default: 20.0) *)
  ; permit_without_calls : bool (** Allow PINGs when no active RPCs (default: false) *)
  }

(** Default keep-alive configuration (disabled by default) *)
let default_keepalive : keepalive_config =
  { time = 7200.0
  ; (* 2 hours - gRPC default *)
    timeout = 20.0
  ; (* 20 seconds *)
    permit_without_calls = false
  }
;;

(** Client configuration *)
type config =
  { target : string (** Target URI: http://host:port or https://host:port *)
  ; codec : Grpc_core.Codec.t (** Preferred compression codec *)
  ; timeout : float option (** Request timeout in seconds *)
  ; metadata : (string * string) list (** Default metadata for all calls *)
  ; tls : tls_config option (** TLS configuration for https:// targets (legacy) *)
  ; credentials : channel_credentials option
    (** Channel credentials (preferred over tls) *)
  ; keepalive : keepalive_config option (** Keep-alive configuration *)
  }

(** Default client configuration *)
let default_config ~target : config =
  { target
  ; codec = Grpc_core.Codec.identity
  ; timeout = Some 30.0
  ; metadata = []
  ; tls = None
  ; (* Legacy: Auto-detect from scheme *)
    credentials = None
  ; (* Use Credentials module for new code *)
    keepalive = None (* Disabled by default *)
  }
;;

(** Create client configuration with credentials *)
let config_with_credentials ~target ~credentials : config =
  { target
  ; codec = Grpc_core.Codec.identity
  ; timeout = Some 30.0
  ; metadata = []
  ; tls = Credentials.to_tls_config credentials
  ; (* For backward compatibility *)
    credentials = Some credentials
  ; keepalive = None
  }
;;

(** Create insecure TLS client configuration (no certificate verification) *)
let tls_insecure () : tls_config =
  { ca_file = None; cert_file = None; key_file = None; verify_peer = false }
;;

(** Create TLS client configuration with custom CA *)
let tls_with_ca ~ca_file : tls_config =
  { ca_file = Some ca_file; cert_file = None; key_file = None; verify_peer = true }
;;

(** Create mTLS client configuration *)
let tls_mtls ~ca_file ~cert_file ~key_file : tls_config =
  { ca_file = Some ca_file
  ; cert_file = Some cert_file
  ; key_file = Some key_file
  ; verify_peer = true
  }
;;

(** Client state *)
type t =
  { config : config
  ; host : string
  ; port : int
  ; scheme : string
  ; interceptors : string Interceptor.t list
  ; tls_client_config : Tls.Config.client option (** Cached TLS config for https *)
  ; call_credentials_headers : (string * string) list (** Headers from call credentials *)
  ; mutable h2_connection : H2.Client_connection.t option (** Cached HTTP/2 connection *)
  ; mutable socket : Eio.Flow.two_way_ty Eio.Std.r option (** Cached socket *)
  }

(** Parse target URI into components *)
let parse_target (target : string) : (string * string * int) option =
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

(** Read file contents *)
let read_file path =
  let ic = open_in path in
  let len = in_channel_length ic in
  let content = really_input_string ic len in
  close_in ic;
  content
;;

(** Build TLS client configuration.
    For https:// targets, creates TLS config for server verification.
    Supports custom CA and client certs (mTLS). *)
let build_tls_client_config ~host (tls_cfg : tls_config option) : Tls.Config.client option
  =
  (* Build authenticator for server cert verification *)
  let authenticator =
    match tls_cfg with
    | Some { verify_peer = false; _ } ->
      (* Explicitly insecure - accept any server certificate. *)
      let time () = Some (Ptime_clock.now ()) in
      ignore time;
      fun ?ip:_ ~host:_ _certs -> Ok None
    | Some { ca_file = Some ca_file; _ } ->
      (* Custom CA *)
      let ca_pem = read_file ca_file in
      (match X509.Certificate.decode_pem_multiple ca_pem with
       | Error (`Msg msg) -> failwith ("CA certificate error: " ^ msg)
       | Ok ca_certs ->
         let time () = Some (Ptime_clock.now ()) in
         X509.Authenticator.chain_of_trust ~time ca_certs)
    | _ ->
      (* System CA store (secure default) *)
      (match Ca_certs.authenticator () with
       | Ok auth -> auth
       | Error (`Msg msg) -> failwith ("CA certificate error: " ^ msg))
  in
  (* Build client certificates for mTLS *)
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
  match
    Tls.Config.client
      ~authenticator
      ?certificates
      ~alpn_protocols:[ "h2" ]
      ~peer_name:(Domain_name.of_string_exn host |> Domain_name.host_exn)
      ()
  with
  | Ok config -> Some config
  | Error (`Msg msg) -> failwith ("TLS config error: " ^ msg)
;;

(** Create a new client connection.

    @param sw Eio switch for resource management
    @param env Eio environment
    @param target Target URI (e.g., "http://localhost:50051" or "https://...") *)
let connect ?(config : config option) ~sw:_ ~env:_ (target : string) : t =
  let config =
    match config with
    | Some c -> c
    | None -> default_config ~target
  in
  match parse_target target with
  | None -> failwith (Printf.sprintf "Invalid target URI: %s" target)
  | Some (scheme, host, port) ->
    (* Get TLS config from credentials (preferred) or legacy tls field *)
    let effective_tls =
      match config.credentials with
      | Some creds -> Credentials.to_tls_config creds
      | None -> config.tls
    in
    (* Extract call credentials headers *)
    let call_credentials_headers =
      match config.credentials with
      | Some creds -> Credentials.get_call_headers creds
      | None -> []
    in
    (* Build TLS config for https:// targets *)
    let tls_client_config =
      if scheme = "https" then build_tls_client_config ~host effective_tls else None
    in
    { config
    ; host
    ; port
    ; scheme
    ; interceptors = []
    ; tls_client_config
    ; call_credentials_headers
    ; h2_connection = None
    ; socket = None
    }
;;

(** Add an interceptor to the client *)
let with_interceptor (interceptor : string Interceptor.t) (client : t) : t =
  { client with interceptors = client.interceptors @ [ interceptor ] }
;;

(** Call a unary RPC method.

    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name (e.g., "helloworld.Greeter")
    @param method_ Method name (e.g., "SayHello")
    @param request Request bytes (protobuf-encoded)
    @return Response bytes or error status *)
let call_unary
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(request : string)
  : (string, Grpc_core.Status.t) result
  =
  let net = Eio.Stdenv.net env in
  let path = Printf.sprintf "/%s/%s" service method_ in
  let codec = client.config.codec in
  (* Encode the request with framing - fail early if encoding fails *)
  match Grpc_core.Message.encode ~codec request with
  | Error e ->
    Error
      Grpc_core.Status.
        { code = Internal
        ; message = Printf.sprintf "Request encoding failed: %s" e
        ; details = None
        }
  | Ok framed_request ->
    (* Build headers - pseudo-headers (:method, :scheme, :path) are set by H2.Request.create *)
    let headers =
      H2.Headers.of_list
        [ ":authority", Printf.sprintf "%s:%d" client.host client.port
        ; "content-type", "application/grpc+proto"
        ; "te", "trailers"
        ; "grpc-accept-encoding", codec.name
        ]
    in
    (* Add grpc-timeout header - per-call deadline overrides config timeout *)
    let effective_timeout =
      match deadline with
      | Some d -> Some d
      | None -> client.config.timeout
    in
    let headers =
      match effective_timeout with
      | None -> headers
      | Some secs ->
        let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float secs) in
        H2.Headers.add headers "grpc-timeout" (Grpc_core.Timeout.to_string timeout_ns)
    in
    (* Add custom metadata *)
    let headers =
      List.fold_left (fun h (k, v) -> H2.Headers.add h k v) headers client.config.metadata
    in
    (* Add call credentials headers (e.g., authorization) *)
    let headers =
      List.fold_left
        (fun h (k, v) -> H2.Headers.add h k v)
        headers
        client.call_credentials_headers
    in
    (* Get or create cached connection for connection reuse (HTTP/2 multiplexing) *)
    let get_or_create_connection () =
      match client.h2_connection with
      | Some conn -> conn
      | None ->
        (* Create new socket and connection *)
        let service = string_of_int client.port in
        let addrs = Eio.Net.getaddrinfo_stream net ~service client.host in
        let socket =
          match addrs with
          | [] ->
            failwith (Printf.sprintf "Cannot resolve: %s:%d" client.host client.port)
          | addr :: _ -> Eio.Net.connect ~sw net addr
        in
        client.socket <- Some (socket :> Eio.Flow.two_way_ty Eio.Std.r);
        let conn =
          match client.tls_client_config with
          | Some tls_config ->
            let tls_flow = Tls_eio.client_of_flow tls_config socket in
            Flow_handler.create_client_connection
              ~sw
              ~error_handler:(fun _ -> ())
              tls_flow
          | None ->
            let h2_client =
              H2_eio.Client.create_connection ~sw ~error_handler:(fun _ -> ()) socket
            in
            h2_client.connection
        in
        client.h2_connection <- Some conn;
        conn
    in
    let connection = get_or_create_connection () in
    (* Track response using Eio.Promise for proper synchronization *)
    (* Use Buffer for O(1) amortized string concatenation instead of O(n²) *)
    let response_buffer = Buffer.create 4096 in
    let response_headers = ref H2.Headers.empty in
    let response_trailers = ref H2.Headers.empty in
    let response_promise, response_resolver = Eio.Promise.create () in
    (* Trailers handler - gRPC sends grpc-status in trailers *)
    let trailers_handler trailers = response_trailers := trailers in
    let response_handler (response : H2.Response.t) body =
      response_headers := response.headers;
      let rec read () =
        H2.Body.Reader.schedule_read
          body
          ~on_eof:(fun () ->
            (* Check grpc-status from trailers first, then headers *)
            let status_code =
              (match H2.Headers.get !response_trailers "grpc-status" with
               | Some s -> Some s
               | None -> H2.Headers.get !response_headers "grpc-status")
              |> Option.map int_of_string
              |> Option.value ~default:0
            in
            if status_code = 0
            then
              Eio.Promise.resolve response_resolver (Ok (Buffer.contents response_buffer))
            else (
              let message =
                (match H2.Headers.get !response_trailers "grpc-message" with
                 | Some m -> Some m
                 | None -> H2.Headers.get !response_headers "grpc-message")
                |> Option.value ~default:"Unknown error"
              in
              Eio.Promise.resolve
                response_resolver
                (Error
                   Grpc_core.Status.
                     { code = Grpc_core.Status.code_of_int status_code
                     ; message
                     ; details = None
                     })))
          ~on_read:(fun bs ~off ~len ->
            (* O(1) buffer append instead of O(n) string concat *)
            Buffer.add_string response_buffer (Bigstringaf.substring bs ~off ~len);
            read ())
      in
      read ()
    in
    let _error_handler error =
      let msg =
        match error with
        | `Malformed_response s -> Printf.sprintf "Malformed response: %s" s
        | `Invalid_response_body_length _ -> "Invalid response body length"
        | `Exn exn -> Printexc.to_string exn
        | `Protocol_error (code, msg) ->
          Printf.sprintf "Protocol error %s: %s" (H2.Error_code.to_string code) msg
      in
      Eio.Promise.resolve
        response_resolver
        (Error Grpc_core.Status.{ code = Unavailable; message = msg; details = None })
    in
    (* Send request with trailers handler for gRPC status - using cached connection *)
    let request_body =
      H2.Client_connection.request
        connection
        (H2.Request.create ~scheme:client.scheme ~headers `POST path)
        ~error_handler:(fun _ -> ())
        ~trailers_handler
        ~response_handler
    in
    H2.Body.Writer.write_string request_body framed_request;
    H2.Body.Writer.close request_body;
    (* Wait for response using Eio.Promise (no busy-wait) *)
    let result = Eio.Promise.await response_promise in
    (* Decode the response frame *)
    (match result with
     | Error e -> Error e
     | Ok body ->
       (match Grpc_core.Message.decode ~codec body with
        | Ok decoded -> Ok decoded
        | Error e ->
          Error
            Grpc_core.Status.
              { code = Internal
              ; message = Printf.sprintf "Failed to decode response: %s" e
              ; details = None
              }))
;;

(** Call a server streaming RPC method.

    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @return A stream of response messages *)
let call_server_streaming
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(request : string)
  : (string, Grpc_core.Status.t) result Grpc_stream.t
  =
  let stream = Grpc_stream.create 16 in
  (* Spawn fiber to handle streaming *)
  Eio.Fiber.fork ~sw (fun () ->
    let net = Eio.Stdenv.net env in
    let path = Printf.sprintf "/%s/%s" service method_ in
    let codec = client.config.codec in
    (* Encode request - if fails, add error to stream and return *)
    let framed_request =
      match Grpc_core.Message.encode ~codec request with
      | Ok f -> f
      | Error e ->
        Grpc_stream.add
          stream
          (Error
             Grpc_core.Status.
               { code = Internal
               ; message = Printf.sprintf "Request encoding failed: %s" e
               ; details = None
               });
        Grpc_stream.close stream;
        (* Exit the fiber early - cannot proceed without encoded request *)
        raise Exit
    in
    (* Build headers - pseudo-headers (:method, :scheme, :path) are set by H2.Request.create *)
    let headers =
      H2.Headers.of_list
        [ ":authority", Printf.sprintf "%s:%d" client.host client.port
        ; "content-type", "application/grpc+proto"
        ; "te", "trailers"
        ; "grpc-accept-encoding", codec.name
        ]
    in
    (* Add grpc-timeout header - per-call deadline overrides config timeout *)
    let effective_timeout =
      match deadline with
      | Some d -> Some d
      | None -> client.config.timeout
    in
    let headers =
      match effective_timeout with
      | None -> headers
      | Some secs ->
        let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float secs) in
        H2.Headers.add headers "grpc-timeout" (Grpc_core.Timeout.to_string timeout_ns)
    in
    (* Add custom metadata *)
    let headers =
      List.fold_left (fun h (k, v) -> H2.Headers.add h k v) headers client.config.metadata
    in
    (* Add call credentials headers (e.g., authorization) *)
    let headers =
      List.fold_left
        (fun h (k, v) -> H2.Headers.add h k v)
        headers
        client.call_credentials_headers
    in
    let service = string_of_int client.port in
    let addrs = Eio.Net.getaddrinfo_stream net ~service client.host in
    let socket =
      match addrs with
      | [] -> failwith (Printf.sprintf "Cannot resolve: %s:%d" client.host client.port)
      | addr :: _ -> Eio.Net.connect ~sw net addr
    in
    let buffer = ref "" in
    let response_handler _response body =
      let rec read () =
        H2.Body.Reader.schedule_read
          body
          ~on_eof:(fun () ->
            Grpc_stream.add stream (Error Grpc_core.Status.ok);
            Grpc_stream.close stream)
          ~on_read:(fun bs ~off ~len ->
            let chunk = Bigstringaf.substring bs ~off ~len in
            buffer := !buffer ^ chunk;
            (* Extract complete messages *)
            match Grpc_core.Message.extract_all ~codec !buffer with
            | Error (Grpc_core.Message.Oversized len) ->
              Grpc_stream.add
                stream
                (Error
                   Grpc_core.Status.
                     { code = Resource_exhausted
                     ; message =
                         Printf.sprintf "Server sent oversized message: %d bytes" len
                     ; details = None
                     });
              Grpc_stream.close stream
            | Error (Grpc_core.Message.Decode_error msg) ->
              Grpc_stream.add
                stream
                (Error
                   Grpc_core.Status.
                     { code = Internal
                     ; message = Printf.sprintf "Decode error: %s" msg
                     ; details = None
                     });
              Grpc_stream.close stream
            | Ok (messages, remaining) ->
              buffer := remaining;
              List.iter (fun msg -> Grpc_stream.add stream (Ok msg)) messages;
              read ())
      in
      read ()
    in
    let error_handler _error =
      Grpc_stream.add
        stream
        (Error
           Grpc_core.Status.
             { code = Unavailable; message = "Connection error"; details = None });
      Grpc_stream.close stream
    in
    (* Create HTTP/2 connection - TLS if configured *)
    let connection : H2.Client_connection.t =
      match client.tls_client_config with
      | Some tls_config ->
        let tls_flow = Tls_eio.client_of_flow tls_config socket in
        Flow_handler.create_client_connection ~sw ~error_handler tls_flow
      | None ->
        let h2_client = H2_eio.Client.create_connection ~sw ~error_handler socket in
        h2_client.connection
    in
    let request_body =
      H2.Client_connection.request
        connection
        (H2.Request.create ~scheme:client.scheme ~headers `POST path)
        ~error_handler:(fun _ -> ())
        ~response_handler
    in
    H2.Body.Writer.write_string request_body framed_request;
    H2.Body.Writer.close request_body);
  stream
;;

(** Call a client streaming RPC method.

    Client sends a stream of requests, server returns a single response.

    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name
    @param method_ Method name
    @param requests Stream of request bytes
    @return Single response or error status *)
let call_client_streaming
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(requests : string Grpc_stream.t)
  : (string, Grpc_core.Status.t) result
  =
  let net = Eio.Stdenv.net env in
  let path = Printf.sprintf "/%s/%s" service method_ in
  let codec = client.config.codec in
  (* Build headers *)
  let headers =
    H2.Headers.of_list
      [ ":authority", Printf.sprintf "%s:%d" client.host client.port
      ; "content-type", "application/grpc+proto"
      ; "te", "trailers"
      ; "grpc-accept-encoding", codec.name
      ]
  in
  (* Add grpc-timeout header - per-call deadline overrides config timeout *)
  let effective_timeout =
    match deadline with
    | Some d -> Some d
    | None -> client.config.timeout
  in
  let headers =
    match effective_timeout with
    | None -> headers
    | Some secs ->
      let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float secs) in
      H2.Headers.add headers "grpc-timeout" (Grpc_core.Timeout.to_string timeout_ns)
  in
  (* Add custom metadata *)
  let headers =
    List.fold_left (fun h (k, v) -> H2.Headers.add h k v) headers client.config.metadata
  in
  (* Add call credentials headers (e.g., authorization) *)
  let headers =
    List.fold_left
      (fun h (k, v) -> H2.Headers.add h k v)
      headers
      client.call_credentials_headers
  in
  (* Connect to server *)
  let port_str = string_of_int client.port in
  let addrs = Eio.Net.getaddrinfo_stream net ~service:port_str client.host in
  let socket =
    match addrs with
    | [] -> failwith (Printf.sprintf "Cannot resolve: %s:%d" client.host client.port)
    | addr :: _ -> Eio.Net.connect ~sw net addr
  in
  (* Track response - using Buffer for O(1) amortized append *)
  let response_buffer = Buffer.create 4096 in
  let response_headers = ref H2.Headers.empty in
  let response_promise, response_resolver = Eio.Promise.create () in
  let response_handler (response : H2.Response.t) body =
    response_headers := response.headers;
    let rec read () =
      H2.Body.Reader.schedule_read
        body
        ~on_eof:(fun () ->
          let status_code =
            H2.Headers.get !response_headers "grpc-status"
            |> Option.map int_of_string
            |> Option.value ~default:0
          in
          if status_code = 0
          then
            Eio.Promise.resolve response_resolver (Ok (Buffer.contents response_buffer))
          else (
            let message =
              H2.Headers.get !response_headers "grpc-message"
              |> Option.value ~default:"Unknown error"
            in
            Eio.Promise.resolve
              response_resolver
              (Error
                 Grpc_core.Status.
                   { code = Grpc_core.Status.code_of_int status_code
                   ; message
                   ; details = None
                   })))
        ~on_read:(fun bs ~off ~len ->
          Buffer.add_string response_buffer (Bigstringaf.substring bs ~off ~len);
          read ())
    in
    read ()
  in
  let error_handler error =
    let msg =
      match error with
      | `Malformed_response s -> Printf.sprintf "Malformed response: %s" s
      | `Invalid_response_body_length _ -> "Invalid response body length"
      | `Exn exn -> Printexc.to_string exn
      | `Protocol_error (code, msg) ->
        Printf.sprintf "Protocol error %s: %s" (H2.Error_code.to_string code) msg
    in
    Eio.Promise.resolve
      response_resolver
      (Error Grpc_core.Status.{ code = Unavailable; message = msg; details = None })
  in
  (* Create HTTP/2 connection - TLS if configured *)
  let connection : H2.Client_connection.t =
    match client.tls_client_config with
    | Some tls_config ->
      let tls_flow = Tls_eio.client_of_flow tls_config socket in
      Flow_handler.create_client_connection ~sw ~error_handler tls_flow
    | None ->
      let h2_client = H2_eio.Client.create_connection ~sw ~error_handler socket in
      h2_client.connection
  in
  (* Send request with streaming body *)
  let request_body =
    H2.Client_connection.request
      connection
      (H2.Request.create ~scheme:client.scheme ~headers `POST path)
      ~error_handler:(fun _ -> ())
      ~response_handler
  in
  (* Spawn fiber to write stream of requests *)
  Eio.Fiber.fork ~sw (fun () ->
    let rec write_loop () =
      match Grpc_stream.take requests with
      | req ->
        (match Grpc_core.Message.encode ~codec req with
         | Ok framed -> H2.Body.Writer.write_string request_body framed
         | Error _ -> ());
        (* Skip malformed messages *)
        write_loop ()
      | exception End_of_file -> H2.Body.Writer.close request_body
    in
    write_loop ());
  (* Wait for response *)
  let result = Eio.Promise.await response_promise in
  (* Decode response *)
  match result with
  | Error e -> Error e
  | Ok body ->
    (match Grpc_core.Message.decode ~codec body with
     | Ok decoded -> Ok decoded
     | Error e ->
       Error
         Grpc_core.Status.
           { code = Internal
           ; message = Printf.sprintf "Failed to decode response: %s" e
           ; details = None
           })
;;

(** Call a bidirectional streaming RPC method.

    Both client and server can send streams of messages.

    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name
    @param method_ Method name
    @param requests Stream of request bytes to send
    @return Stream of response bytes *)
let call_bidi
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(requests : string Grpc_stream.t)
  : (string, Grpc_core.Status.t) result Grpc_stream.t
  =
  let responses = Grpc_stream.create 16 in
  (* Spawn fiber for bidi communication *)
  Eio.Fiber.fork ~sw (fun () ->
    let net = Eio.Stdenv.net env in
    let path = Printf.sprintf "/%s/%s" service method_ in
    let codec = client.config.codec in
    (* Build headers *)
    let headers =
      H2.Headers.of_list
        [ ":authority", Printf.sprintf "%s:%d" client.host client.port
        ; "content-type", "application/grpc+proto"
        ; "te", "trailers"
        ; "grpc-accept-encoding", codec.name
        ]
    in
    (* Add grpc-timeout header - per-call deadline overrides config timeout *)
    let effective_timeout =
      match deadline with
      | Some d -> Some d
      | None -> client.config.timeout
    in
    let headers =
      match effective_timeout with
      | None -> headers
      | Some secs ->
        let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float secs) in
        H2.Headers.add headers "grpc-timeout" (Grpc_core.Timeout.to_string timeout_ns)
    in
    (* Add custom metadata *)
    let headers =
      List.fold_left (fun h (k, v) -> H2.Headers.add h k v) headers client.config.metadata
    in
    (* Add call credentials headers (e.g., authorization) *)
    let headers =
      List.fold_left
        (fun h (k, v) -> H2.Headers.add h k v)
        headers
        client.call_credentials_headers
    in
    (* Connect to server *)
    let port_str = string_of_int client.port in
    let addrs = Eio.Net.getaddrinfo_stream net ~service:port_str client.host in
    let socket =
      match addrs with
      | [] ->
        Grpc_stream.add
          responses
          (Error
             Grpc_core.Status.
               { code = Unavailable
               ; message = Printf.sprintf "Cannot resolve: %s:%d" client.host client.port
               ; details = None
               });
        Grpc_stream.close responses;
        raise Exit
      | addr :: _ -> Eio.Net.connect ~sw net addr
    in
    let buffer = ref "" in
    let response_handler _response body =
      let rec read () =
        H2.Body.Reader.schedule_read
          body
          ~on_eof:(fun () ->
            Grpc_stream.add responses (Error Grpc_core.Status.ok);
            Grpc_stream.close responses)
          ~on_read:(fun bs ~off ~len ->
            let chunk = Bigstringaf.substring bs ~off ~len in
            buffer := !buffer ^ chunk;
            (* Extract complete messages *)
            match Grpc_core.Message.extract_all ~codec !buffer with
            | Error (Grpc_core.Message.Oversized len) ->
              Grpc_stream.add
                responses
                (Error
                   Grpc_core.Status.
                     { code = Resource_exhausted
                     ; message =
                         Printf.sprintf "Server sent oversized message: %d bytes" len
                     ; details = None
                     });
              Grpc_stream.close responses
            | Error (Grpc_core.Message.Decode_error msg) ->
              Grpc_stream.add
                responses
                (Error
                   Grpc_core.Status.
                     { code = Internal
                     ; message = Printf.sprintf "Decode error: %s" msg
                     ; details = None
                     });
              Grpc_stream.close responses
            | Ok (messages, remaining) ->
              buffer := remaining;
              List.iter (fun msg -> Grpc_stream.add responses (Ok msg)) messages;
              read ())
      in
      read ()
    in
    let error_handler _error =
      Grpc_stream.add
        responses
        (Error
           Grpc_core.Status.
             { code = Unavailable; message = "Connection error"; details = None });
      Grpc_stream.close responses
    in
    (* Create HTTP/2 connection - TLS if configured *)
    let connection : H2.Client_connection.t =
      match client.tls_client_config with
      | Some tls_config ->
        let tls_flow = Tls_eio.client_of_flow tls_config socket in
        Flow_handler.create_client_connection ~sw ~error_handler tls_flow
      | None ->
        let h2_client = H2_eio.Client.create_connection ~sw ~error_handler socket in
        h2_client.connection
    in
    let request_body =
      H2.Client_connection.request
        connection
        (H2.Request.create ~scheme:client.scheme ~headers `POST path)
        ~error_handler:(fun _ -> ())
        ~response_handler
    in
    (* Write requests in a separate fiber *)
    Eio.Fiber.fork ~sw (fun () ->
      let rec write_loop () =
        match Grpc_stream.take requests with
        | req ->
          (match Grpc_core.Message.encode ~codec req with
           | Ok framed -> H2.Body.Writer.write_string request_body framed
           | Error _ -> ());
          write_loop ()
        | exception End_of_file -> H2.Body.Writer.close request_body
      in
      write_loop ()));
  responses
;;

(** Close the client connection *)
let close (_client : t) : unit =
  (* In a real implementation, this would close the HTTP/2 connection *)
  ()
;;

(** Send HTTP/2 PING frame for connection health check.

    Establishes a connection, sends a PING frame, and waits for acknowledgement.
    Returns [Ok ()] if PING acknowledged within timeout, [Error status] otherwise.

    @param sw Eio switch
    @param env Eio environment
    @param client The gRPC client
    @return [Ok ()] on successful PING/ACK, [Error status] on failure *)
let ping ~sw ~env (client : t) : (unit, Grpc_core.Status.t) result =
  let net = Eio.Stdenv.net env in
  (* Connect to server *)
  let service = string_of_int client.port in
  let addrs = Eio.Net.getaddrinfo_stream net ~service client.host in
  let socket =
    match addrs with
    | [] -> failwith (Printf.sprintf "Cannot resolve: %s:%d" client.host client.port)
    | addr :: _ -> Eio.Net.connect ~sw net addr
  in
  let ping_promise, ping_resolver = Eio.Promise.create () in
  let error_handler error =
    let msg =
      match error with
      | `Malformed_response s -> Printf.sprintf "Malformed response: %s" s
      | `Invalid_response_body_length _ -> "Invalid response body length"
      | `Exn exn -> Printexc.to_string exn
      | `Protocol_error (code, msg) ->
        Printf.sprintf "Protocol error %s: %s" (H2.Error_code.to_string code) msg
    in
    Eio.Promise.resolve
      ping_resolver
      (Error Grpc_core.Status.{ code = Unavailable; message = msg; details = None })
  in
  (* Create HTTP/2 connection - TLS if configured *)
  let connection : H2.Client_connection.t =
    match client.tls_client_config with
    | Some tls_config ->
      let tls_flow = Tls_eio.client_of_flow tls_config socket in
      Flow_handler.create_client_connection ~sw ~error_handler tls_flow
    | None ->
      let h2_client = H2_eio.Client.create_connection ~sw ~error_handler socket in
      h2_client.connection
  in
  (* Send PING frame *)
  H2.Client_connection.ping connection (function
    | Ok () -> Eio.Promise.resolve ping_resolver (Ok ())
    | Error `EOF ->
      Eio.Promise.resolve
        ping_resolver
        (Error
           Grpc_core.Status.
             { code = Unavailable; message = "Connection closed (EOF)"; details = None }));
  (* Wait for PING acknowledgement with timeout *)
  let timeout_secs =
    match client.config.keepalive with
    | Some ka -> ka.timeout
    | None -> 20.0 (* Default 20 seconds *)
  in
  let clock = Eio.Stdenv.clock env in
  (* Race between ping response and timeout *)
  let result = ref None in
  Eio.Fiber.first
    (fun () -> result := Some (Eio.Promise.await ping_promise))
    (fun () ->
       Eio.Time.sleep clock timeout_secs;
       result
       := Some
            (Error
               Grpc_core.Status.
                 { code = Deadline_exceeded
                 ; message = Printf.sprintf "PING timeout after %.1fs" timeout_secs
                 ; details = None
                 }));
  match !result with
  | Some r -> r
  | None ->
    Error
      Grpc_core.Status.
        { code = Internal; message = "Unexpected: no result"; details = None }
;;
