(** gRPC Health Checking Protocol (v1) implementation.

    Implements the standard gRPC health checking protocol as defined in:
    https://github.com/grpc/grpc/blob/master/doc/health-checking.md

    Usage:
    {[
      let health = Health.create () in
      Health.set_status health ~service:"myapp.Greeter" Serving;

      let server = Server.create ()
        |> Server.add_service (Health.to_service health)
        |> Server.serve ~sw ~env
    ]} *)

(** Serving status as defined by gRPC Health Checking Protocol *)
type status =
  | Unknown (** 0 - Status unknown *)
  | Serving (** 1 - Service is healthy and serving *)
  | Not_serving (** 2 - Service is not serving (unhealthy) *)
  | Service_unknown (** 3 - Service name not recognized *)

(** Health service state (abstract) *)
type t

(** Create a new health service.
    @param default_status Initial status for unregistered services (default: Unknown) *)
val create : ?default_status:status -> unit -> t

(** Set the health status for a service.
    @param service Service name (empty string "" for overall server health)
    @param status New status *)
val set_status : t -> service:string -> status -> unit

(** Get the health status for a service.
    @param service Service name (empty string "" for overall server health)
    @return Current status *)
val get_status : t -> service:string -> status

(** Set the default status for the overall server *)
val set_default_status : t -> status -> unit

(** Mark all registered services as serving *)
val set_all_serving : t -> unit

(** Mark all registered services as not serving (for graceful shutdown) *)
val set_all_not_serving : t -> unit

(** Register a service name (sets initial status to Unknown) *)
val register_service : t -> service:string -> unit

(** List all registered services *)
val list_services : t -> string list

(** Convert health service to a gRPC service.
    Creates a Service.t that can be added to a server with:
    {[ Server.add_service (Health.to_service health) server ]} *)
val to_service : t -> Service.t

(** Create Watch stream for a service (for streaming health updates) *)
val watch : t -> service:string -> status Grpc_stream.t
