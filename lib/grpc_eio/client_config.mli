(** Client configuration types, credential abstractions, and metadata encoding. *)

(** {1 TLS Configuration} *)

(** Client TLS configuration *)
type tls_config =
  { ca_file : string option (** CA cert for server verification (None = system CA) *)
  ; cert_file : string option (** Client cert for mTLS *)
  ; key_file : string option (** Client key for mTLS *)
  ; verify_peer : bool (** Verify server certificate (default true) *)
  }

(** Create insecure TLS config (no certificate verification).
    {b Warning:} Only use for testing. *)
val tls_insecure : unit -> tls_config

(** Create TLS config with custom CA certificate for server verification *)
val tls_with_ca : ca_file:string -> tls_config

(** Create mTLS config with client certificate for mutual authentication *)
val tls_mtls : ca_file:string -> cert_file:string -> key_file:string -> tls_config

(** {1 Channel Credentials} *)

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
module Credentials : sig
  (** Create insecure (plaintext) credentials *)
  val insecure : unit -> channel_credentials

  (** Create TLS credentials with optional CA file *)
  val tls : ?ca_file:string -> unit -> channel_credentials

  (** Create mTLS credentials with client certificate *)
  val mtls
    :  ca_file:string
    -> cert_file:string
    -> key_file:string
    -> unit
    -> channel_credentials

  (** Create TLS config (for use with with_token) *)
  val tls_config
    :  ?ca_file:string
    -> ?cert_file:string
    -> ?key_file:string
    -> unit
    -> tls_config

  (** Add call credentials (bearer token) to channel credentials *)
  val with_token : token:string -> ?tls:tls_config -> unit -> channel_credentials

  (** Add custom header credentials to channel credentials *)
  val with_headers
    :  headers:(string * string) list
    -> ?tls:tls_config
    -> unit
    -> channel_credentials

  (** Add dynamic credentials (computed per-call) *)
  val with_compute_creds
    :  f:(unit -> (string * string) list)
    -> ?tls:tls_config
    -> unit
    -> channel_credentials

  (** Check if credentials require TLS *)
  val requires_tls : channel_credentials -> bool

  (** Extract TLS config from credentials *)
  val to_tls_config : channel_credentials -> tls_config option

  (** Extract call credentials headers *)
  val get_call_headers : channel_credentials -> (string * string) list
end

(** {1 Metadata} *)

module Metadata : sig
  (** Check if a metadata key uses binary encoding (ends with "-bin") *)
  val is_bin_key : string -> bool

  (** Encode metadata headers, base64-encoding binary values *)
  val encode_headers : (string * string) list -> (string * string) list

  (** Decode a base64-encoded binary metadata value *)
  val decode_bin_value : string -> string option
end

(** {1 Keep-alive Configuration} *)

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

(** Default keep-alive configuration *)
val default_keepalive : keepalive_config

(** {1 Client Configuration} *)

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

(** Default client configuration with identity codec and 30s timeout *)
val default_config : target:string -> config

(** Create client configuration with credentials *)
val config_with_credentials : target:string -> credentials:channel_credentials -> config

(** {1 Utility Functions} *)

(** Percent-decode a URI-encoded string *)
val percent_decode : string -> string

(** Add metadata headers to an H2 header set *)
val add_metadata : H2.Headers.t -> (string * string) list -> H2.Headers.t

(** Map HTTP status code to gRPC status code *)
val map_http_status_code : int -> Grpc_core.Status.code
