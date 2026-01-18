(** gRPC Client using Eio and h2.

    A type-safe gRPC client built on OCaml 5's effect system.
    Supports all four gRPC call types: unary, server streaming,
    client streaming, and bidirectional streaming.

    {b TLS Support:}
    - http://  → Plain HTTP/2
    - https:// → TLS with server verification
    - mTLS     → Mutual TLS with client certificate

    {b Thread Safety:}
    - Single-domain safe: Yes
    - Multi-domain safe: Yes - uses Grpc_eio.Stream/Promise for synchronization

    {b TLS Example:}
    {[
      (* Server verification with custom CA *)
      let tls = Client.tls_with_ca ~ca_file:"./ca.pem" in
      let config = { default_config ~target:"https://localhost:50051" with tls = Some tls } in
      let client = Client.connect ~config ~sw ~env "https://localhost:50051"

      (* mTLS with client certificate *)
      let tls = Client.tls_mtls
        ~ca_file:"./ca.pem"
        ~cert_file:"./client.pem"
        ~key_file:"./client.key"
      in
      let config = { default_config ~target:"https://localhost:50051" with tls = Some tls } in
      let client = Client.connect ~config ~sw ~env "https://localhost:50051"
    ]} *)

(** {1 TLS Configuration} *)

(** Client TLS configuration *)
type tls_config = {
  ca_file : string option;    (** CA cert for server verification (None = system CA) *)
  cert_file : string option;  (** Client cert for mTLS *)
  key_file : string option;   (** Client key for mTLS *)
  verify_peer : bool;         (** Verify server certificate (default true) *)
}

(** Create insecure TLS config (no certificate verification).
    {b Warning:} Only use for testing! *)
val tls_insecure : unit -> tls_config

(** Create TLS config with custom CA certificate for server verification *)
val tls_with_ca : ca_file:string -> tls_config

(** Create mTLS config with client certificate for mutual authentication *)
val tls_mtls : ca_file:string -> cert_file:string -> key_file:string -> tls_config

(** {1 Channel Credentials} *)

(** Per-RPC credentials for authentication tokens.
    These credentials are attached to each RPC call. *)
type call_credentials =
  | BearerToken of string                    (** OAuth2 Bearer token *)
  | CustomHeader of (string * string) list   (** Custom authentication headers *)
  | ComputeCallCreds of (unit -> (string * string) list)  (** Dynamic credentials *)

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
    ]} *)
type channel_credentials =
  | Insecure                                         (** No TLS, plaintext HTTP/2 *)
  | Tls of tls_config                                (** TLS with optional mTLS *)
  | WithCallCredentials of {
      transport : channel_credentials;               (** Underlying transport credentials *)
      call_creds : call_credentials;                 (** Per-RPC credentials *)
    }

(** Credentials module for unified authentication abstraction *)
module Credentials : sig
  (** Create insecure (plaintext) credentials *)
  val insecure : unit -> channel_credentials

  (** Create TLS credentials with optional CA file *)
  val tls : ?ca_file:string -> unit -> channel_credentials

  (** Create mTLS credentials with client certificate *)
  val mtls : ca_file:string -> cert_file:string -> key_file:string -> unit -> channel_credentials

  (** Create TLS config (for use with with_token) *)
  val tls_config : ?ca_file:string -> ?cert_file:string -> ?key_file:string -> unit -> tls_config

  (** Add call credentials (bearer token) to channel credentials *)
  val with_token : token:string -> ?tls:tls_config -> unit -> channel_credentials

  (** Add custom header credentials to channel credentials *)
  val with_headers : headers:(string * string) list -> ?tls:tls_config -> unit -> channel_credentials

  (** Add dynamic credentials (computed per-call) *)
  val with_compute_creds : f:(unit -> (string * string) list) -> ?tls:tls_config -> unit -> channel_credentials

  (** Check if credentials require TLS *)
  val requires_tls : channel_credentials -> bool

  (** Extract TLS config from credentials *)
  val to_tls_config : channel_credentials -> tls_config option

  (** Extract call credentials headers *)
  val get_call_headers : channel_credentials -> (string * string) list
end

(** {1 Keep-alive Configuration} *)

(** Keep-alive configuration.

    gRPC uses HTTP/2 PING frames for connection health checking.
    When enabled, the client periodically sends PING frames and
    expects acknowledgements within a timeout period.

    {b Example:}
    {[
      let keepalive = {
        time = 60.0;              (* Send PING every 60 seconds *)
        timeout = 10.0;           (* Wait 10 seconds for ACK *)
        permit_without_calls = true;
      } in
      let config = { default_config ~target with keepalive = Some keepalive }
    ]}

    @see {{: https://grpc.io/docs/guides/keepalive/ } gRPC Keepalive Guide} *)
type keepalive_config = {
  time : float;           (** Interval between PINGs in seconds (default: 7200.0 = 2 hours) *)
  timeout : float;        (** Time to wait for PING ACK in seconds (default: 20.0) *)
  permit_without_calls : bool;  (** Allow PINGs when no active RPCs (default: false) *)
}

(** Default keep-alive configuration *)
val default_keepalive : keepalive_config

(** {1 Client Configuration} *)

(** Client configuration *)
type config = {
  target : string;  (** Target URI: http://host:port or https://host:port *)
  codec : Grpc_core.Codec.t;  (** Preferred compression codec *)
  timeout : float option;  (** Request timeout in seconds *)
  metadata : (string * string) list;  (** Default metadata for all calls *)
  tls : tls_config option;  (** TLS configuration for https:// targets (legacy) *)
  credentials : channel_credentials option;  (** Channel credentials (preferred over tls) *)
  keepalive : keepalive_config option;  (** Keep-alive configuration *)
}

(** Default client configuration with identity codec and 30s timeout *)
val default_config : target:string -> config

(** Create client configuration with credentials.
    This is the recommended way to configure authentication.

    {b Example:}
    {[
      let creds = Credentials.mtls
        ~ca_file:"./ca.pem"
        ~cert_file:"./client.pem"
        ~key_file:"./client.key"
        ()
      in
      let config = config_with_credentials ~target:"https://localhost:50051" ~credentials:creds in
      let client = Client.connect ~config ~sw ~env target
    ]} *)
val config_with_credentials : target:string -> credentials:channel_credentials -> config

(** Client connection state *)
type t

(** Create a new client connection.

    @param config Optional client configuration
    @param sw Eio switch for resource management
    @param env Eio environment
    @param target Target URI (e.g., "http://localhost:50051")
    @raise Failure if target URI is invalid *)
val connect : ?config:config -> sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> string -> t

(** Add an interceptor to the client.

    Interceptors are applied in order for requests. *)
val with_interceptor : string Interceptor.t -> t -> t

(** Call a unary RPC method.

    Single request, single response.

    @param sw Eio switch
    @param env Eio environment
    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name (e.g., "helloworld.Greeter")
    @param method_ Method name (e.g., "SayHello")
    @param request Request bytes (protobuf-encoded)
    @return Response bytes or error status *)
val call_unary :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?deadline:float ->
  t ->
  service:string ->
  method_:string ->
  request:string ->
  (string, Grpc_core.Status.t) result

(** Call a server streaming RPC method.

    Single request, stream of responses.

    @param sw Eio switch
    @param env Eio environment
    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name
    @param method_ Method name
    @param request Request bytes
    @return Stream of response messages. Stream ends with [Error Status.ok] on success. *)
val call_server_streaming :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?deadline:float ->
  t ->
  service:string ->
  method_:string ->
  request:string ->
  (string, Grpc_core.Status.t) result Grpc_stream.t

(** Call a client streaming RPC method.

    Stream of requests, single response.
    Caller must close [requests] with [Grpc_eio.Stream.close] to finish the stream.

    @param sw Eio switch
    @param env Eio environment
    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name
    @param method_ Method name
    @param requests Stream of request bytes to send
    @return Single response or error status *)
val call_client_streaming :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?deadline:float ->
  t ->
  service:string ->
  method_:string ->
  requests:string Grpc_stream.t ->
  (string, Grpc_core.Status.t) result

(** Call a bidirectional streaming RPC method.

    Stream of requests, stream of responses. Both can be sent/received
    concurrently. Caller must close [requests] with [Grpc_eio.Stream.close]
    to half-close the stream.

    @param sw Eio switch
    @param env Eio environment
    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name
    @param method_ Method name
    @param requests Stream of request bytes to send
    @return Stream of response messages *)
val call_bidi :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?deadline:float ->
  t ->
  service:string ->
  method_:string ->
  requests:string Grpc_stream.t ->
  (string, Grpc_core.Status.t) result Grpc_stream.t

(** Close the client connection *)
val close : t -> unit

(** {1 Health Check} *)

(** Send HTTP/2 PING frame for connection health check.

    Establishes a connection, sends a PING frame, and waits for acknowledgement.
    Uses the keepalive timeout from config, or 20 seconds by default.

    This is useful for:
    - Testing if a server is reachable
    - Pre-warming connections before sending requests
    - Implementing custom keep-alive logic

    @param sw Eio switch
    @param env Eio environment
    @param client The gRPC client
    @return [Ok ()] on successful PING/ACK, [Error status] on failure *)
val ping :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  t ->
  (unit, Grpc_core.Status.t) result
