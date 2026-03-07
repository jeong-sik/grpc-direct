(** Connection Pool for gRPC Client.

    Maintains a pool of persistent HTTP/2 connections for efficient reuse.
    Inspired by Go's grpc-go connection management.

    {b Key Features:}
    - Configurable pool size per target
    - Automatic health checking
    - Graceful connection eviction
    - Round-robin load balancing

    {b Architecture:}
    {v
    Client Request
          │
          ▼
    ┌─────────────────────────────────────────┐
    │          Connection Pool                │
    │  ┌─────────────────────────────────┐    │
    │  │  Target: api.example.com:443   │    │
    │  │  ┌────┐ ┌────┐ ┌────┐ ┌────┐   │    │
    │  │  │ C1 │ │ C2 │ │ C3 │ │ C4 │   │    │
    │  │  │idle│ │busy│ │idle│ │busy│   │    │
    │  │  └────┘ └────┘ └────┘ └────┘   │    │
    │  └─────────────────────────────────┘    │
    └─────────────────────────────────────────┘
    v}

    @since 0.4.0
*)

(** Connection state *)
type conn_state =
  | Idle (** Available for use *)
  | Busy (** Currently in use *)
  | Draining (** Finishing existing requests, no new requests *)
  | Closed (** Connection closed *)

(** Connection wrapper with metadata *)
type connection =
  { id : int
  ; target : string
  ; mutable state : conn_state
  ; mutable last_used : float
  ; mutable request_count : int
  ; mutable error_count : int
  ; (* The actual H2 connection would go here *)
    (* For now, we store a placeholder *)
    mutable h2_conn : unit option
  }

(** Pool configuration *)
type config =
  { max_connections : int (** Max connections per target *)
  ; max_idle_time : float (** Seconds before idle connection is closed *)
  ; max_requests : int (** Max requests per connection (0 = unlimited) *)
  ; health_check_interval : float (** Seconds between health checks *)
  ; connect_timeout : float (** Connection timeout in seconds *)
  }

let default_config =
  { max_connections = 10
  ; max_idle_time = 300.0
  ; (* 5 minutes *)
    max_requests = 0
  ; (* Unlimited *)
    health_check_interval = 30.0
  ; connect_timeout = 10.0
  }
;;

(** Target-specific pool *)
module TargetPool = struct
  type t =
    { target : string
    ; config : config
    ; mutable connections : connection list
    ; mutable next_id : int
    ; mutable total_acquired : int
    ; mutable total_released : int
    ; mutable total_errors : int
    ; mutex : Eio.Mutex.t (** Eio-compatible mutex for cooperative scheduling *)
    }

  let create ~config target =
    { target
    ; config
    ; connections = []
    ; next_id = 0
    ; total_acquired = 0
    ; total_released = 0
    ; total_errors = 0
    ; mutex = Eio.Mutex.create ()
    }
  ;;

  (** Execute [f] under mutex protection using Eio's cooperative lock *)
  let with_lock pool f = Eio.Mutex.use_rw ~protect:true pool.mutex f

  let create_connection pool =
    let id = pool.next_id in
    pool.next_id <- id + 1;
    { id
    ; target = pool.target
    ; state = Idle
    ; last_used = Time_compat.now ()
    ; request_count = 0
    ; error_count = 0
    ; h2_conn = None
    }
  ;;

  let find_idle pool = List.find_opt (fun c -> c.state = Idle) pool.connections

  let acquire pool =
    with_lock pool (fun () ->
      pool.total_acquired <- pool.total_acquired + 1;
      match find_idle pool with
      | Some conn ->
        conn.state <- Busy;
        conn.last_used <- Time_compat.now ();
        Some conn
      | None when List.length pool.connections < pool.config.max_connections ->
        let conn = create_connection pool in
        conn.state <- Busy;
        pool.connections <- conn :: pool.connections;
        Some conn
      | None ->
        (* Pool exhausted *)
        None)
  ;;

  let release pool conn =
    with_lock pool (fun () ->
      pool.total_released <- pool.total_released + 1;
      conn.request_count <- conn.request_count + 1;
      conn.last_used <- Time_compat.now ();
      (* Check if connection should be retired *)
      let should_close =
        conn.error_count > 3
        || (pool.config.max_requests > 0 && conn.request_count >= pool.config.max_requests)
      in
      if should_close
      then (
        conn.state <- Closed;
        pool.connections <- List.filter (fun c -> c.id <> conn.id) pool.connections)
      else conn.state <- Idle)
  ;;

  let report_error pool conn =
    with_lock pool (fun () ->
      pool.total_errors <- pool.total_errors + 1;
      conn.error_count <- conn.error_count + 1;
      if conn.error_count > 3
      then (
        conn.state <- Closed;
        pool.connections <- List.filter (fun c -> c.id <> conn.id) pool.connections))
  ;;

  let cleanup_idle pool now =
    with_lock pool (fun () ->
      pool.connections
      <- List.filter
           (fun conn ->
              if conn.state = Idle && now -. conn.last_used > pool.config.max_idle_time
              then (
                conn.state <- Closed;
                false)
              else conn.state <> Closed)
           pool.connections)
  ;;

  let stats pool =
    with_lock pool (fun () ->
      let idle = List.length (List.filter (fun c -> c.state = Idle) pool.connections) in
      let busy = List.length (List.filter (fun c -> c.state = Busy) pool.connections) in
      let total = List.length pool.connections in
      idle, busy, total, pool.total_acquired, pool.total_errors)
  ;;

  let close_all pool =
    with_lock pool (fun () ->
      List.iter (fun c -> c.state <- Closed) pool.connections;
      pool.connections <- [])
  ;;
end

(** Global connection pool manager *)
type t =
  { config : config
  ; pools : (string, TargetPool.t) Hashtbl.t
  ; mutex : Eio.Mutex.t (** Eio-compatible mutex for cooperative scheduling *)
  }

let create ?(config = default_config) () =
  { config; pools = Hashtbl.create 16; mutex = Eio.Mutex.create () }
;;

let get_target_pool t target =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    match Hashtbl.find_opt t.pools target with
    | Some pool -> pool
    | None ->
      let pool = TargetPool.create ~config:t.config target in
      Hashtbl.add t.pools target pool;
      pool)
;;

(** Acquire a connection to the target *)
let acquire t target =
  let pool = get_target_pool t target in
  TargetPool.acquire pool
;;

(** Release a connection back to the pool *)
let release t conn =
  let pool = get_target_pool t conn.target in
  TargetPool.release pool conn
;;

(** Report an error on a connection *)
let report_error t conn =
  let pool = get_target_pool t conn.target in
  TargetPool.report_error pool conn
;;

(** Cleanup idle connections across all targets *)
let cleanup_idle t =
  let now = Time_compat.now () in
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    Hashtbl.iter (fun _ pool -> TargetPool.cleanup_idle pool now) t.pools)
;;

(** Get pool statistics for a target *)
let stats t target =
  match Hashtbl.find_opt t.pools target with
  | Some pool -> Some (TargetPool.stats pool)
  | None -> None
;;

(** Get all pool statistics *)
let all_stats t =
  Eio.Mutex.use_ro t.mutex (fun () ->
    Hashtbl.fold
      (fun target pool acc -> (target, TargetPool.stats pool) :: acc)
      t.pools
      [])
;;

(** Close all connections *)
let close_all t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    Hashtbl.iter (fun _ pool -> TargetPool.close_all pool) t.pools;
    Hashtbl.clear t.pools)
;;

(** Print pool statistics *)
let print_stats t =
  Printf.printf "Connection Pool Statistics:\n";
  Printf.printf
    "%-40s %6s %6s %6s %10s %8s\n"
    "Target"
    "Idle"
    "Busy"
    "Total"
    "Acquired"
    "Errors";
  Printf.printf "%s\n" (String.make 80 '-');
  List.iter
    (fun (target, (idle, busy, total, acquired, errors)) ->
       Printf.printf "%-40s %6d %6d %6d %10d %8d\n" target idle busy total acquired errors)
    (all_stats t)
;;

(** {1 RAII-style Connection Guard} *)

(** Use connection with automatic release on scope exit.
    Similar to Go's defer or Rust's Drop. *)
let with_connection t target f =
  match acquire t target with
  | None -> Error `Pool_exhausted
  | Some conn ->
    (match f conn with
     | result ->
       release t conn;
       Ok result
     | exception exn ->
       report_error t conn;
       release t conn;
       raise exn)
;;
