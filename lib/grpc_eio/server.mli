(** gRPC Server using Eio and h2.

    A high-performance gRPC server built on OCaml 5's effect system.
    Supports all four gRPC call types and TLS encryption.

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

(** {1 Configuration} *)

(** Server configuration *)
type config = {
  host : string;                        (** Bind address (default: 127.0.0.1) *)
  port : int;                           (** Bind port (default: 50051) *)
  codecs : Grpc_core.Codec.t list;      (** Supported compression codecs *)
  max_message_size : int;               (** Max message size (default: 4MB) *)
  default_timeout : Grpc_core.Timeout.t option;  (** Default request timeout *)
  tls : Tls_config.t option;            (** TLS configuration (optional) *)
}

(** Default server configuration *)
val default_config : config

(** {1 Server Type} *)

(** Server state *)
type t

(** {1 Server Creation} *)

(** Create a new gRPC server.
    @param config Optional server configuration *)
val create : ?config:config -> unit -> t

(** Add a service to the server.
    Services should be added before calling [serve]. *)
val add_service : Service.t -> t -> t

(** Add an interceptor to the server.
    Interceptors are applied in order for incoming requests. *)
val with_interceptor : string Interceptor.t -> t -> t

(** Attach a metrics registry to the server. *)
val with_metrics : Metrics.t -> t -> t

(** {1 Server Operations} *)

(** Start serving requests.
    This function blocks until [shutdown] is called.

    @param sw Eio switch for resource management
    @param env Eio environment *)
val serve : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> t -> unit

(** Shutdown the server gracefully.
    Signals the server to stop accepting new connections. *)
val shutdown : t -> unit

(** {1 Query} *)

(** List all registered service names *)
val list_services : t -> string list

(** Get the supported encodings string *)
val supported_encodings : t -> string

(** {1 Internal} *)

(** Lookup a method by path.
    @return (service, method_def, codec) or error status *)
val lookup_method : t -> string ->
  (Service.t * Service.method_def * Grpc_core.Codec.t, Grpc_core.Status.t) result

(** Handle a unary request.
    Used internally by the HTTP/2 handler. *)
val handle_request :
  t ->
  clock:_ Eio.Time.clock ->
  path:string ->
  metadata:(string * string) list ->
  body:string ->
  request_codec:Grpc_core.Codec.t ->
  response_codec:Grpc_core.Codec.t ->
  (string * (string * string) list * Grpc_core.Codec.t, Grpc_core.Status.t) result

(** Handle a unary request with decoded message data. *)
val handle_decoded_request :
  t ->
  clock:_ Eio.Time.clock ->
  path:string ->
  metadata:(string * string) list ->
  request_data:string ->
  response_codec:Grpc_core.Codec.t ->
  method_def:Service.method_def ->
  (string * (string * string) list * Grpc_core.Codec.t, Grpc_core.Status.t) result

(** {1 Multi-domain Support}

    These functions are exposed for use by [Server_multi].
    Most users should use [serve] or [Server_multi.serve_multi] instead. *)

(** HTTP/2 request handler.
    Handles a single gRPC request within an HTTP/2 connection.
    @param sw Eio switch for spawning fibers
    @param clock Eio clock for timeout enforcement *)
val request_handler :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  t ->
  H2.Reqd.t ->
  unit

(** HTTP/2 error handler.
    Called when connection-level errors occur. *)
val error_handler :
  Eio.Net.Sockaddr.stream ->
  ?request:H2.Request.t ->
  H2.Server_connection.error ->
  (H2.Headers.t -> H2.Body.Writer.t) ->
  unit

(** Access server config (for multi-domain cloning) *)
val config : t -> config

(** Access server services (for multi-domain cloning) *)
val services : t -> (string, Service.t) Hashtbl.t

(** Access server interceptors (for multi-domain cloning) *)
val interceptors : t -> string Interceptor.t list

(** Access server metrics registry (for multi-domain cloning) *)
val metrics : t -> Metrics.t option

(** Check/set running state *)
val running : t -> bool
val set_running : t -> bool -> unit
