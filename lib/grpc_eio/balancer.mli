(** Client-side Load Balancing for gRPC.

    Implements load balancing strategies for distributing requests
    across multiple backend servers.

    Usage:
    {[
      let balancer = Balancer.create
        ~strategy:RoundRobin
        ~targets:["http://server1:50051"; "http://server2:50051"]
        ()
      in
      Balancer.call ~sw ~env balancer (fun client ->
        Client.call_unary client ~service:"..." ~method_:"..." ~request
      )
    ]} *)

(** Load balancing strategy *)
type strategy =
  | PickFirst (** Use first available connection *)
  | RoundRobin (** Distribute evenly across backends *)
  | WeightedRoundRobin of int list (** Distribute based on weights *)
  | Random (** Random selection *)

(** Backend state *)
type backend_state =
  | Healthy
  | Unhealthy
  | Unknown

(** Pool options for per-backend connection reuse. *)
type pool_options =
  { min_connections : int
  ; max_connections : int
  ; idle_timeout : float
  ; health_check_interval : float
  ; connection_timeout : float
  ; client_config : Client.config option
  }

(** Default pool options (matches Pool defaults). *)
val default_pool_options : pool_options

(** Load balancer (abstract) *)
type t

(** Create a load balancer.

    @param strategy Load balancing strategy (default: RoundRobin)
    @param targets List of backend URIs (required, at least 1)
    @param health_check_interval Seconds between health checks (default: 10)
    @param failure_threshold Failures before marking unhealthy (default: 3)
    @param recovery_threshold Successes before marking healthy (default: 2)
    @param pool_options Enable per-backend connection pooling when provided

    Example:
    {[
      (* Round Robin *)
      let lb = Balancer.create
        ~targets:["http://server1:50051"; "http://server2:50051"]
        ()

      (* Weighted Round Robin *)
      let lb = Balancer.create
        ~strategy:(WeightedRoundRobin [3; 1])  (* 3:1 ratio *)
        ~targets:["http://fast:50051"; "http://slow:50051"]
        ()
    ]} *)
val create
  :  ?strategy:strategy
  -> ?health_check_interval:float
  -> ?failure_threshold:int
  -> ?recovery_threshold:int
  -> ?pool_options:pool_options
  -> targets:string list
  -> unit
  -> t

(** Execute a function with load-balanced client selection.

    Automatically:
    - Selects a healthy backend
    - Creates a client connection
    - Records success/failure for health tracking

    @raise Failure if no healthy backends available *)
val call : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> t -> (Client.t -> 'a) -> 'a

(** Execute with automatic retry on different backend.

    On failure, automatically retries with a different backend
    up to max_retries times.

    @param max_retries Maximum retry attempts (default: 2) *)
val call_with_retry
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> ?max_retries:int
  -> t
  -> (Client.t -> 'a)
  -> 'a

(** Get list of all backends with their current states *)
val backends : t -> (string * backend_state) list

(** Get count of healthy backends *)
val healthy_count : t -> int

(** Get total backend count *)
val total_count : t -> int

(** Manually mark a backend as unhealthy.

    Use for circuit breaker or manual failover scenarios. *)
val mark_unhealthy : t -> string -> unit

(** Manually mark a backend as healthy.

    Use to restore a backend after maintenance. *)
val mark_healthy : t -> string -> unit

(** Format balancer state as string for logging *)
val to_string : t -> string
