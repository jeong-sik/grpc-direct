(** Connection Pool for gRPC Client.

    Maintains persistent HTTP/2 connections for efficient reuse,
    reducing connection overhead for high-throughput scenarios.

    {b Usage:}
    {[
      let pool = Connection_pool.create () in

      (* RAII-style usage (recommended) *)
      Connection_pool.with_connection pool "api.example.com:443"
        (fun conn ->
          (* Use connection... *)
          do_rpc conn request
        )

      (* Manual acquire/release *)
      match Connection_pool.acquire pool "api.example.com:443" with
      | Some conn ->
          (* Use connection... *)
          Connection_pool.release pool conn
      | None ->
          (* Pool exhausted *)
          failwith "No connections available"
    ]}

    @since 0.4.0
*)

(** {1 Types} *)

(** Connection state *)
type conn_state =
  | Idle (** Available for use *)
  | Busy (** Currently in use *)
  | Draining (** Finishing existing requests *)
  | Closed (** Connection closed *)

(** Connection wrapper *)
type connection =
  { id : int
  ; target : string
  ; mutable state : conn_state
  ; mutable last_used : float
  ; mutable request_count : int
  ; mutable error_count : int
  ; mutable h2_conn : unit option
  }

(** Pool configuration *)
type config =
  { max_connections : int (** Max connections per target (default: 10) *)
  ; max_idle_time : float (** Seconds before idle eviction (default: 300) *)
  ; max_requests : int (** Max requests per connection, 0=unlimited (default: 0) *)
  ; health_check_interval : float (** Health check interval (default: 30) *)
  ; connect_timeout : float (** Connection timeout (default: 10) *)
  }

(** Default pool configuration *)
val default_config : config

(** Connection pool manager *)
type t

(** {1 Pool Operations} *)

(** Create a new connection pool.
    @param config Optional configuration overrides *)
val create : ?config:config -> unit -> t

(** Acquire a connection to the target.
    Returns [None] if pool is exhausted. *)
val acquire : t -> string -> connection option

(** Release a connection back to the pool. *)
val release : t -> connection -> unit

(** Report an error on a connection.
    Connections with too many errors are automatically closed. *)
val report_error : t -> connection -> unit

(** Cleanup idle connections that exceed max_idle_time. *)
val cleanup_idle : t -> unit

(** Get pool statistics for a specific target.
    Returns [(idle, busy, total, acquired, errors)] *)
val stats : t -> string -> (int * int * int * int * int) option

(** Get statistics for all targets *)
val all_stats : t -> (string * (int * int * int * int * int)) list

(** Close all connections and clear the pool *)
val close_all : t -> unit

(** Print formatted statistics to stdout *)
val print_stats : t -> unit

(** {1 RAII-Style Usage} *)

(** Use connection with automatic release.
    The connection is always released, even on exceptions.

    @return [Ok result] on success, [Error `Pool_exhausted] if no connection available
    @raise Reraises any exception from the function after releasing connection *)
val with_connection
  :  t
  -> string
  -> (connection -> 'a)
  -> ('a, [> `Pool_exhausted ]) result
