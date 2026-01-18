(** gRPC-Web client over HTTP/1.1. *)

type tls_config = {
  ca_file : string option;
  cert_file : string option;
  key_file : string option;
  verify_peer : bool;
}

val tls_insecure : unit -> tls_config
val tls_with_ca : ca_file:string -> tls_config
val tls_mtls : ca_file:string -> cert_file:string -> key_file:string -> tls_config

type config = {
  target : string;
  mode : Grpc_web.mode;
  codec : Grpc_core.Codec.t;
  timeout : float option;
  metadata : (string * string) list;
  tls : tls_config option;
}

type t

(** Default client config *)
val default_config : target:string -> config

(** Create a client for a gRPC-Web endpoint.
    @param env Eio environment *)
val connect :
  ?config:config ->
  env:Eio_unix.Stdenv.base ->
  string ->
  t

(** Unary call *)
val call_unary :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?deadline:float ->
  t ->
  service:string ->
  method_:string ->
  request:string ->
  (string, Grpc_core.Status.t) result

(** Server streaming call (responses delivered via stream). *)
val call_server_streaming :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?deadline:float ->
  t ->
  service:string ->
  method_:string ->
  request:string ->
  (string, Grpc_core.Status.t) result Grpc_stream.t

(** Client streaming call (requests are buffered before send).
    Caller must close [requests] with [Grpc_eio.Stream.close]. *)
val call_client_streaming :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?deadline:float ->
  t ->
  service:string ->
  method_:string ->
  requests:string Grpc_stream.t ->
  (string, Grpc_core.Status.t) result

(** Bidirectional streaming call (requests are buffered before send).
    Caller must close [requests] with [Grpc_eio.Stream.close]. *)
val call_bidi :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?deadline:float ->
  t ->
  service:string ->
  method_:string ->
  requests:string Grpc_stream.t ->
  (string, Grpc_core.Status.t) result Grpc_stream.t

(** Close client resources. *)
val close : t -> unit
