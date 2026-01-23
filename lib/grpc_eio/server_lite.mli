(** Server_lite - High-performance gRPC server using h2_lite

    This server uses our custom h2_lite HTTP/2 stack, achieving 87.7% of
    grpc-go performance (43,280 req/s vs 49,349 req/s).

    @see <https://www.rfc-editor.org/rfc/rfc7540> HTTP/2 Specification *)

(** {1 Configuration} *)

(** Server configuration *)
type config =
  { host : string
  ; port : int
  ; max_concurrent_streams : int
  }

(** Default configuration: 127.0.0.1:50051, 100 concurrent streams *)
val default_config : config

(** {1 Server} *)

(** Server state *)
type t

(** Create a new server with optional configuration *)
val create : ?config:config -> unit -> t

(** Add a service to the server *)
val add_service : Service.t -> t -> t

(** {1 Running} *)

(** Start serving multiple services.

    @param sw Eio switch for lifecycle management
    @param env Eio environment for network access
    @param config Server configuration
    @param services List of gRPC services to serve *)
val serve
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> ?config:config
  -> Service.t list
  -> unit

(** Convenience function for serving a single service.

    @param sw Eio switch
    @param env Eio environment
    @param port Listen port
    @param service Single gRPC service *)
val serve_service
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> port:int
  -> Service.t
  -> unit
