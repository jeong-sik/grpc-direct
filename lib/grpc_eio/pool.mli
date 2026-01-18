(** Connection Pool for gRPC clients.

    Manages a pool of reusable connections to improve performance
    by avoiding connection setup overhead for each request.

    Usage:
    {[
      let pool = Pool.create ~target:"http://localhost:50051" () in

      (* Use with automatic release (recommended) *)
      Pool.with_connection ~sw ~env pool (fun client ->
        Client.call_unary client ~service:"..." ~method_:"..." ~request
      )

      (* Or manual acquire/release *)
      let client = Pool.acquire ~sw ~env pool in
      let result = Client.call_unary client ... in
      Pool.release pool client;
      result
    ]} *)

(** Pool configuration *)
type config = {
  target : string;
  min_connections : int;
  max_connections : int;
  idle_timeout : float;
  health_check_interval : float;
  connection_timeout : float;
  client_config : Client.config option;
}

(** Default pool configuration *)
val default_config : target:string -> config

(** Connection pool (abstract) *)
type t

(** Create a new connection pool.

    @param target Target URI (required)
    @param min_connections Minimum idle connections (default: 1)
    @param max_connections Maximum total connections (default: 10)
    @param idle_timeout Seconds before closing idle connections (default: 300)
    @param health_check_interval Seconds between health checks (default: 30)
    @param connection_timeout Seconds to wait for connection (default: 5)
    @param client_config Optional client configuration *)
val create :
  ?min_connections:int ->
  ?max_connections:int ->
  ?idle_timeout:float ->
  ?health_check_interval:float ->
  ?connection_timeout:float ->
  ?client_config:Client.config ->
  target:string ->
  unit ->
  t

(** Acquire a connection from the pool.

    - Returns an idle connection if available
    - Creates a new connection if below max_connections
    - Blocks if max reached (or fails)

    @raise Failure if pool is closed *)
val acquire : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> t -> Client.t

(** Release a connection back to the pool *)
val release : t -> Client.t -> unit

(** Use a connection with automatic release.

    This is the recommended way to use pooled connections:
    {[
      Pool.with_connection ~sw ~env pool (fun client ->
        Client.call_unary client ~service:"..." ~method_:"..." ~request
      )
    ]} *)
val with_connection :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  t ->
  (Client.t -> 'a) ->
  'a

(** Close the pool and release all connections *)
val close : t -> unit

(** Pool statistics *)
type stats = {
  total_connections : int;
  in_use_connections : int;
  idle_connections : int;
  acquired_count : int;
  released_count : int;
  created_count : int;
  evicted_count : int;
}

(** Get pool statistics *)
val stats : t -> stats

(** Get current pool size *)
val size : t -> int

(** Get number of available (idle) connections *)
val available : t -> int

(** Check if pool is closed *)
val is_closed : t -> bool

(** Pre-warm the pool by creating min_connections.

    Call after creation to avoid cold-start latency:
    {[
      let pool = Pool.create ~target () in
      Pool.warm_up ~sw ~env pool;
    ]} *)
val warm_up : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> t -> unit

(** Format stats as string for logging *)
val stats_to_string : stats -> string
