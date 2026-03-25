(** Client connection management: URI parsing, TLS setup, connect/close/ping. *)

open Client_config

(** Client connection state *)
type t =
  { config : config
  ; host : string
  ; port : int
  ; scheme : string
  ; interceptors : string Interceptor.t list
  ; tls_client_config : Tls.Config.client option
  ; call_credentials_headers : (string * string) list
  ; mutable h2_connection : H2.Client_connection.t option
  ; mutable socket : Eio.Flow.two_way_ty Eio.Std.r option
  }

(** Parse target URI into (scheme, host, port) *)
val parse_target : string -> (string * string * int) option

(** Build TLS client configuration from optional TLS config *)
val build_tls_client_config
  :  host:string
  -> tls_config option
  -> (Tls.Config.client option, string) result

(** Specific exception for client connection errors *)
exception Connection_error of string

(** Create a new client connection.
    @raise Connection_error if the target URI is invalid or TLS configuration fails *)
val connect : ?config:config -> sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> string -> t

(** Add an interceptor to the client *)
val with_interceptor : string Interceptor.t -> t -> t

(** Close the client connection *)
val close : t -> unit

(** Send HTTP/2 PING frame for connection health check.
    Returns [Ok ()] if PING acknowledged within timeout, [Error status] otherwise. *)
val ping
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> t
  -> (unit, Grpc_core.Status.t) result
