(** gRPC-Web server over HTTP/1.1. *)

type cors_config = {
  allow_origin : string;
  allow_methods : string list;
  allow_headers : string list;
  expose_headers : string list;
  allow_credentials : bool;
  max_age : int option;
}

val default_cors : cors_config

type config = {
  addr : Eio.Net.Sockaddr.stream;
  cors : cors_config;
  tls : Tls_config.t option;
  max_request_body : int;
}

(** Default config derived from gRPC server settings. *)
val default_config : Server.t -> config

(** Serve gRPC-Web (HTTP/1.1) with CORS support.
    This uses a separate port from the HTTP/2 gRPC server. *)
val serve :
  ?config:config ->
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  Server.t ->
  unit
