(** gRPC-Web WebSocket gateway (browser client/bidi streaming). *)

type config =
  { addr : Eio.Net.Sockaddr.stream
  ; tls : Tls_config.t option
  ; max_frame_size : int
  ; subprotocols : string list
  }

(** Default config derived from gRPC server settings. *)
val default_config : Server.t -> config

(** Serve gRPC-Web over WebSocket (HTTP/1.1 upgrade).
    One RPC is served per WebSocket connection. *)
val serve
  :  ?config:config
  -> sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> Server.t
  -> unit
