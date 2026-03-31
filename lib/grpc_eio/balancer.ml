(** Client-side Load Balancing for gRPC.

    Implements load balancing strategies for distributing requests
    across multiple backend servers.

    Supported strategies:
    - Round Robin: Distribute requests evenly
    - Pick First: Use first available connection
    - Weighted Round Robin: Distribute based on weights

    {b Thread Safety:}
    - Single-domain safe: Yes
    - Multi-domain safe: Yes - all mutable state protected by [Eio.Mutex]
    - Backend list and state changes synchronized via [Eio.Mutex.use_rw]

    @see {{: https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md } Eio Multicore Guide}

    Usage:
    {[
      let balancer = Balancer.create
        ~strategy:RoundRobin
        ~targets:["http://server1:50051"; "http://server2:50051"]
        ()
      in
      Balancer.call balancer ~sw ~env (fun client ->
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

(** Backend endpoint *)
type backend =
  { target : string
  ; weight : int
  ; mutable state : backend_state
  ; mutable consecutive_failures : int
  ; mutable last_check : float
  }

(** Load balancer configuration *)
type config =
  { strategy : strategy
  ; health_check_interval : float (** Seconds between health checks *)
  ; failure_threshold : int (** Failures before marking unhealthy *)
  ; recovery_threshold : int (** Successes before marking healthy *)
  }

(** Pool options for per-backend connection reuse *)
type pool_options =
  { min_connections : int
  ; max_connections : int
  ; idle_timeout : float
  ; health_check_interval : float
  ; connection_timeout : float
  ; client_config : Client.config option
  }

(** Default pool options (matches Pool defaults) *)
let default_pool_options : pool_options =
  { min_connections = 1
  ; max_connections = 10
  ; idle_timeout = 300.0
  ; health_check_interval = 30.0
  ; connection_timeout = 5.0
  ; client_config = None
  }
;;

(** Default configuration *)
let _default_config : config =
  { strategy = RoundRobin
  ; health_check_interval = 10.0
  ; failure_threshold = 3
  ; recovery_threshold = 2
  }
;;

(** Load balancer state *)
type t =
  { config : config
  ; backends : backend array
  ; mutable current_index : int (** For round robin *)
  ; mutex : Eio.Mutex.t
  ; pool_options : pool_options option
  ; pools : (string, Pool.t) Hashtbl.t
  }

(** Create a backend from target string *)
let create_backend ?(weight = 1) (target : string) : backend =
  { target; weight; state = Unknown; consecutive_failures = 0; last_check = 0.0 }
;;

(** Create a load balancer.

    @param strategy Load balancing strategy
    @param targets List of backend URIs
    @param weights Optional weights for WeightedRoundRobin *)
let create
      ?(strategy = RoundRobin)
      ?(health_check_interval = 10.0)
      ?(failure_threshold = 3)
      ?(recovery_threshold = 2)
      ?pool_options
      ~targets
      ()
  : t
  =
  if List.length targets = 0 then failwith "At least one target is required";
  let weights =
    match strategy with
    | WeightedRoundRobin ws -> ws
    | PickFirst | RoundRobin | Random -> List.map (fun _ -> 1) targets
  in
  let backends =
    List.map2 (fun target weight -> create_backend ~weight target) targets weights
    |> Array.of_list
  in
  { config = { strategy; health_check_interval; failure_threshold; recovery_threshold }
  ; backends
  ; current_index = 0
  ; mutex = Eio.Mutex.create ()
  ; pool_options
  ; pools = Hashtbl.create 16
  }
;;

let get_pool (balancer : t) (target : string) : Pool.t option =
  match balancer.pool_options with
  | None -> None
  | Some opts ->
    let pool =
      Eio.Mutex.use_rw ~protect:true balancer.mutex (fun () ->
        match Hashtbl.find_opt balancer.pools target with
        | Some existing -> existing
        | None ->
          let created =
            Pool.create
              ~min_connections:opts.min_connections
              ~max_connections:opts.max_connections
              ~idle_timeout:opts.idle_timeout
              ~health_check_interval:opts.health_check_interval
              ~connection_timeout:opts.connection_timeout
              ?client_config:opts.client_config
              ~target
              ()
          in
          Hashtbl.add balancer.pools target created;
          created)
    in
    Some pool
;;

(** Check if backend is available for selection *)
let is_available (backend : backend) : bool = backend.state <> Unhealthy

(** Select next backend using Pick First strategy *)
let pick_first (balancer : t) : backend option =
  Array.to_seq balancer.backends |> Seq.find is_available
;;

(** Select next backend using Round Robin strategy *)
let round_robin (balancer : t) : backend option =
  let n = Array.length balancer.backends in
  let start = balancer.current_index in
  let rec find_next i count =
    if count >= n
    then None
    else (
      let backend = balancer.backends.(i) in
      if is_available backend
      then (
        balancer.current_index <- (i + 1) mod n;
        Some backend)
      else find_next ((i + 1) mod n) (count + 1))
  in
  find_next start 0
;;

(** Select next backend using Weighted Round Robin *)
let weighted_round_robin (balancer : t) : backend option =
  (* Simple implementation: expand by weights and round robin *)
  let available = Array.to_list balancer.backends |> List.filter is_available in
  if List.length available = 0
  then None
  else (
    let total_weight = List.fold_left (fun acc b -> acc + b.weight) 0 available in
    if total_weight = 0
    then None
    else (
      let idx = balancer.current_index mod total_weight in
      balancer.current_index <- balancer.current_index + 1;
      let rec find_weighted backends acc =
        match backends with
        | [] -> None
        | b :: rest ->
          let new_acc = acc + b.weight in
          if idx < new_acc then Some b else find_weighted rest new_acc
      in
      find_weighted available 0))
;;

(** Select next backend using Random strategy *)
let random_select (balancer : t) : backend option =
  let available =
    Array.to_list balancer.backends |> List.filter is_available |> Array.of_list
  in
  let n = Array.length available in
  if n = 0 then None else Some available.(Random.int n)
;;

(** Select next backend based on strategy *)
let select_backend (balancer : t) : backend option =
  Eio.Mutex.use_rw ~protect:true balancer.mutex (fun () ->
    match balancer.config.strategy with
    | PickFirst -> pick_first balancer
    | RoundRobin -> round_robin balancer
    | WeightedRoundRobin _ -> weighted_round_robin balancer
    | Random -> random_select balancer)
;;

(** Record success for a backend *)
let record_success (balancer : t) (backend : backend) : unit =
  Eio.Mutex.use_rw ~protect:true balancer.mutex (fun () ->
    backend.consecutive_failures <- 0;
    if backend.state = Unhealthy
    then
      (* Recovery logic could be added here *)
      backend.state <- Healthy
    else if backend.state = Unknown
    then backend.state <- Healthy)
;;

(** Record failure for a backend *)
let record_failure (balancer : t) (backend : backend) : unit =
  Eio.Mutex.use_rw ~protect:true balancer.mutex (fun () ->
    backend.consecutive_failures <- backend.consecutive_failures + 1;
    if backend.consecutive_failures >= balancer.config.failure_threshold
    then backend.state <- Unhealthy)
;;

(** Run [f] against the backend's pool or a fresh connection, then
    record success/failure on the balancer. *)
let run_on_backend ~sw ~env (balancer : t) (backend : backend) (f : Client.t -> 'a) : 'a =
  let execute () =
    match get_pool balancer backend.target with
    | Some pool ->
      (match Pool.with_connection ~sw ~env pool f with
       | Ok v -> v
       | Error msg -> failwith msg)
    | None ->
      let client = Client.connect ~sw ~env backend.target in
      f client
  in
  try
    let result = execute () in
    record_success balancer backend;
    result
  with
  | exn ->
    record_failure balancer backend;
    raise exn
;;

(** Execute a function with load-balanced client selection.

    Automatically selects a backend and records success/failure.

    @raise Failure if no backends available *)
let call ~sw ~env (balancer : t) (f : Client.t -> 'a) : 'a =
  match select_backend balancer with
  | None -> failwith "No healthy backends available"
  | Some backend -> run_on_backend ~sw ~env balancer backend f
;;

(** Execute with automatic retry on different backend *)
let call_with_retry ~sw ~env ?(max_retries = 2) (balancer : t) (f : Client.t -> 'a) : 'a =
  let rec attempt n =
    match select_backend balancer with
    | None -> failwith "No healthy backends available"
    | Some backend ->
      (try run_on_backend ~sw ~env balancer backend f with
       | exn -> if n < max_retries then attempt (n + 1) else raise exn)
  in
  attempt 0
;;

(** Get list of all backends with their states *)
let backends (balancer : t) : (string * backend_state) list =
  Eio.Mutex.use_ro balancer.mutex (fun () ->
    Array.to_list balancer.backends |> List.map (fun b -> b.target, b.state))
;;

(** Get count of healthy backends *)
let healthy_count (balancer : t) : int =
  Eio.Mutex.use_ro balancer.mutex (fun () ->
    Array.fold_left
      (fun acc b -> if is_available b then acc + 1 else acc)
      0
      balancer.backends)
;;

(** Get total backend count *)
let total_count (balancer : t) : int = Array.length balancer.backends

(** Manually mark a backend as unhealthy *)
let mark_unhealthy (balancer : t) (target : string) : unit =
  Eio.Mutex.use_rw ~protect:true balancer.mutex (fun () ->
    Array.iter
      (fun b -> if String.equal b.target target then b.state <- Unhealthy)
      balancer.backends)
;;

(** Manually mark a backend as healthy *)
let mark_healthy (balancer : t) (target : string) : unit =
  Eio.Mutex.use_rw ~protect:true balancer.mutex (fun () ->
    Array.iter
      (fun b ->
         if String.equal b.target target
         then (
           b.state <- Healthy;
           b.consecutive_failures <- 0))
      balancer.backends)
;;

(** Add a new backend dynamically *)
let _add_backend (balancer : t) ?(weight = 1) (target : string) : unit =
  Eio.Mutex.use_rw ~protect:true balancer.mutex (fun () ->
    let new_backend = create_backend ~weight target in
    let new_backends = Array.append balancer.backends [| new_backend |] in
    (* Note: This is a simplified implementation. In production,
       we'd need to handle the immutable array differently *)
    Array.blit new_backends 0 balancer.backends 0 (Array.length balancer.backends))
;;

(** Format balancer state as string for logging *)
let to_string (balancer : t) : string =
  Eio.Mutex.use_ro balancer.mutex (fun () ->
    let strategy_str =
      match balancer.config.strategy with
      | PickFirst -> "PickFirst"
      | RoundRobin -> "RoundRobin"
      | WeightedRoundRobin _ -> "WeightedRoundRobin"
      | Random -> "Random"
    in
    let backends_str =
      Array.to_list balancer.backends
      |> List.map (fun b ->
        let state_str =
          match b.state with
          | Healthy -> "H"
          | Unhealthy -> "U"
          | Unknown -> "?"
        in
        Printf.sprintf "%s[%s]" b.target state_str)
      |> String.concat ", "
    in
    let n_healthy =
      Array.fold_left
        (fun acc b -> if is_available b then acc + 1 else acc)
        0
        balancer.backends
    in
    Printf.sprintf
      "Balancer[%s, %d/%d healthy]: %s"
      strategy_str
      n_healthy
      (Array.length balancer.backends)
      backends_str)
;;
