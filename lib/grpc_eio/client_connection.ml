(** Client connection management: URI parsing, TLS setup, connect/close/ping.

    This module handles the transport layer for gRPC clients -- establishing
    connections, negotiating TLS, and performing health checks via HTTP/2 PING. *)

open Client_config

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

let read_file = File_util.read_file

(** Build TLS client configuration.
    For https:// targets, creates TLS config for server verification.
    Supports custom CA and client certs (mTLS). *)
let build_tls_client_config ~host (tls_cfg : tls_config option)
  : (Tls.Config.client option, string) result
  =
  (* Build authenticator for server cert verification *)
  let authenticator_result =
    match tls_cfg with
    | Some { verify_peer = false; _ } ->
      (* Explicitly insecure - accept any server certificate. *)
      let time () = Some (Ptime_clock.now ()) in
      ignore time;
      Ok (fun ?ip:_ ~host:_ _certs -> Ok None)
    | Some { ca_file = Some ca_file; _ } ->
      (* Custom CA *)
      let ca_pem = read_file ca_file in
      (match X509.Certificate.decode_pem_multiple ca_pem with
       | Error (`Msg msg) -> Error ("CA certificate error: " ^ msg)
       | Ok ca_certs ->
         let time () = Some (Ptime_clock.now ()) in
         Ok (X509.Authenticator.chain_of_trust ~time ca_certs))
    | _ ->
      (* System CA store (secure default) *)
      (match Ca_certs.authenticator () with
       | Ok auth -> Ok auth
       | Error (`Msg msg) -> Error ("CA certificate error: " ^ msg))
  in
  match authenticator_result with
  | Error msg -> Error msg
  | Ok authenticator ->
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
    (match
       Tls.Config.client
         ~authenticator
         ?certificates
         ~alpn_protocols:[ "h2" ]
         ~peer_name:(Domain_name.of_string_exn host |> Domain_name.host_exn)
         ()
     with
     | Ok config -> Ok (Some config)
     | Error (`Msg msg) -> Error ("TLS config error: " ^ msg))
;;

(** Specific exception for client connection errors.
    Replaces generic [Failure] to allow callers to catch connection
    errors distinctly from other failures. *)
exception Connection_error of string

(** Create a new client connection.

    @param sw Eio switch for resource management
    @param env Eio environment
    @param target Target URI (e.g., "http://localhost:50051" or "https://...")
    @raise Connection_error if the target URI is invalid or TLS configuration fails *)
let connect ?(config : config option) ~sw:_ ~env:_ (target : string) : t =
  let config =
    match config with
    | Some c -> c
    | None -> default_config ~target
  in
  match parse_target target with
  | None -> raise (Connection_error (Printf.sprintf "Invalid target URI: %s" target))
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
      if scheme = "https"
      then (
        match build_tls_client_config ~host effective_tls with
        | Ok cfg -> cfg
        | Error msg -> raise (Connection_error msg))
      else None
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
    (match !result with
     | Some r -> r
     | None ->
       Error
         Grpc_core.Status.
           { code = Internal; message = "Unexpected: no result"; details = None })
;;
