(** Client configuration types, credential abstractions, and metadata encoding.

    Contains all type definitions and helper constructors needed to configure
    a gRPC client connection. The {!Credentials} module provides a unified
    authentication API similar to Go's [grpc.WithTransportCredentials]. *)

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
    Similar to Go's [grpc.WithTransportCredentials]. *)
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

module Metadata = struct
  let is_bin_key key =
    let suffix = "-bin" in
    let key_len = String.length key in
    let suffix_len = String.length suffix in
    key_len >= suffix_len
    && String.equal (String.sub key (key_len - suffix_len) suffix_len) suffix
  ;;

  let encode_headers metadata =
    List.map
      (fun (k, v) -> if is_bin_key k then k, Grpc_web.Base64.encode v else k, v)
      metadata
  ;;

  let decode_bin_value value =
    match Grpc_web.Base64.decode value with
    | Ok v -> Some v
    | Error _ -> None
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

(** Percent-decode a URI-encoded string *)
let percent_decode (s : string) =
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len
    then Ok (Buffer.contents buf)
    else (
      match s.[i] with
      | '%' when i + 2 < len ->
        let hex = String.sub s (i + 1) 2 in
        (match int_of_string_opt ("0x" ^ hex) with
         | Some code ->
           Buffer.add_char buf (Char.chr code);
           loop (i + 3)
         | None -> Error ())
      | '%' -> Error ()
      | c ->
        Buffer.add_char buf c;
        loop (i + 1))
  in
  match loop 0 with
  | Ok v -> v
  | Error _ -> s
;;

(** Add metadata headers to an H2 header set *)
let add_metadata headers metadata =
  Metadata.encode_headers metadata
  |> List.fold_left (fun h (k, v) -> H2.Headers.add h k v) headers
;;

(** Map HTTP status code to gRPC status code *)
let map_http_status_code code =
  match code with
  | 400 -> Grpc_core.Status.Internal
  | 401 -> Grpc_core.Status.Unauthenticated
  | 403 -> Grpc_core.Status.Permission_denied
  | 404 -> Grpc_core.Status.Unimplemented
  | 429 | 502 | 503 | 504 -> Grpc_core.Status.Unavailable
  | _ -> Grpc_core.Status.Unknown
;;
