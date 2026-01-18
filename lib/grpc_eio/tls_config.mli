(** TLS configuration for gRPC server.

    Uses tls-eio for pure OCaml TLS with ALPN "h2" negotiation.

    {b Features:}
    - Server TLS: Basic HTTPS-style encryption
    - mTLS: Mutual TLS with client certificate verification

    {b Basic TLS Example:}
    {[
      let tls = Tls_config.create
        ~cert_file:"./server.pem"
        ~key_file:"./server.key"
      in
      let server = Server.create ~config:{ default_config with tls = Some tls } ()
    ]}

    {b mTLS Example:}
    {[
      let tls = Tls_config.create_mtls
        ~cert_file:"./server.pem"
        ~key_file:"./server.key"
        ~ca_file:"./ca.pem"
      in
      let server = Server.create ~config:{ default_config with tls = Some tls } ()
    ]} *)

(** {1 Types} *)

(** Client authentication mode for mTLS *)
type client_auth =
  | NoClientCert        (** Don't request client certificate (default TLS) *)
  | RequestClientCert   (** Request but don't require client certificate *)
  | RequireAndVerify    (** Require and verify client certificate (mTLS) *)

(** TLS configuration *)
type t = {
  cert_file : string;           (** Path to PEM certificate file *)
  key_file : string;            (** Path to PEM private key file *)
  ca_file : string option;      (** Optional CA cert for client verification (mTLS) *)
  client_auth : client_auth;    (** Client authentication mode *)
}

(** {1 Constructors} *)

(** Create a basic TLS config (server-only authentication).
    Client certificates are not requested. *)
val create : cert_file:string -> key_file:string -> t

(** Create mTLS config (mutual authentication).
    Client certificates are required and verified against the CA. *)
val create_mtls : cert_file:string -> key_file:string -> ca_file:string -> t

(** {1 Loading} *)

(** Load TLS server configuration from files.
    Returns Tls.Config.server with ALPN set to "h2".
    @raise Failure if cert/key files are invalid *)
val load : t -> Tls.Config.server

(** Load TLS server configuration for HTTP/1.1 (gRPC-Web).
    Returns Tls.Config.server with ALPN set to "http/1.1". *)
val load_http1 : t -> Tls.Config.server

(** Validate TLS files can be loaded.
    @return true if valid
    @raise Failure if invalid *)
val validate : t -> bool

(** {1 Query} *)

(** Check if mTLS (mutual authentication) is enabled *)
val is_mtls : t -> bool
