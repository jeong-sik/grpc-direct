(** gRPC Retry Policy implementation.

    Implements retry with exponential backoff and jitter as specified in:
    https://github.com/grpc/proposal/blob/master/A6-client-retries.md

    {b Thread Safety:}
    - Single-domain safe: Yes (cooperative scheduling)
    - Multi-domain safe: {b No} - TokenBucket uses mutable fields without synchronization
    - For multi-domain: Use [Atomic.t] for token bucket remaining/last_refill

    @see {{: https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md } Eio Multicore Guide}

    Usage:
    {[
      let policy = Retry.{
        max_attempts = 3;
        initial_backoff = 0.1;  (* 100ms *)
        max_backoff = 1.0;      (* 1s *)
        backoff_multiplier = 2.0;
        retryable_codes = [Unavailable; Resource_exhausted];
      } in
      let client = Client.connect ~sw ~env uri
        |> Client.with_interceptor (Retry.interceptor ~policy ())
    ]} *)

(** Retry policy configuration *)
type policy = {
  max_attempts : int;           (** Maximum number of attempts (including initial) *)
  initial_backoff : float;      (** Initial backoff in seconds *)
  max_backoff : float;          (** Maximum backoff in seconds *)
  backoff_multiplier : float;   (** Multiplier for exponential backoff *)
  retryable_codes : Grpc_core.Status.code list;  (** Status codes to retry *)
  jitter : float;               (** Jitter factor (0.0 to 1.0) *)
}

(** Default retry policy *)
let default_policy : policy = {
  max_attempts = 3;
  initial_backoff = 0.1;      (* 100ms *)
  max_backoff = 1.0;          (* 1 second *)
  backoff_multiplier = 2.0;
  retryable_codes = [
    Grpc_core.Status.Unavailable;
    Grpc_core.Status.Resource_exhausted;
    Grpc_core.Status.Aborted;
  ];
  jitter = 0.2;               (* 20% jitter *)
}

(** Check if a status code is retryable *)
let is_retryable (policy : policy) (code : Grpc_core.Status.code) : bool =
  List.mem code policy.retryable_codes

(** Calculate backoff with exponential increase and jitter.

    Formula: min(initial * multiplier^attempt, max) * (1 - jitter + random(0, 2*jitter))

    The jitter is applied as a ±jitter% variation to spread out retry thundering herd. *)
let calculate_backoff (policy : policy) (attempt : int) : float =
  let base = policy.initial_backoff *. (policy.backoff_multiplier ** float_of_int attempt) in
  let capped = Float.min base policy.max_backoff in
  (* Apply jitter: value * (1 - jitter + random(0, 2*jitter)) *)
  let jitter_range = 2.0 *. policy.jitter in
  let jitter_factor = 1.0 -. policy.jitter +. (Random.float jitter_range) in
  capped *. jitter_factor

(** Sleep for the specified duration using Eio *)
let sleep_seconds (seconds : float) : unit =
  Eio_unix.sleep seconds

(** Retry interceptor for client-side retry logic.

    This interceptor wraps the RPC call and retries on retryable errors
    according to the specified policy.

    @param policy Retry policy configuration
    @param on_retry Optional callback when retry occurs *)
let interceptor
    ?(policy = default_policy)
    ?(on_retry : (int -> Grpc_core.Status.code -> float -> unit) option)
    ()
  : string Interceptor.t =
  Interceptor.make ~name:"retry" (fun ctx next ->
    let rec attempt n =
      try
        let result = next ctx in
        result
      with
      | Failure _msg when n < policy.max_attempts - 1 ->
          (* Check if this is a gRPC error we should retry *)
          (* For now, retry on generic failures *)
          let backoff = calculate_backoff policy n in
          (match on_retry with
           | Some f -> f n Grpc_core.Status.Unknown backoff
           | None -> ());
          sleep_seconds backoff;
          attempt (n + 1)
    in
    attempt 0
  )

(** Result-based retry for explicit error handling.

    Unlike the interceptor which catches exceptions, this function
    handles Result types explicitly for more control. *)
let with_retry
    ?(policy = default_policy)
    ?(on_retry : (int -> Grpc_core.Status.t -> float -> unit) option)
    (f : unit -> ('a, Grpc_core.Status.t) result)
  : ('a, Grpc_core.Status.t) result =
  let rec attempt n =
    match f () with
    | Ok v -> Ok v
    | Error status when n < policy.max_attempts - 1 && is_retryable policy status.code ->
        let backoff = calculate_backoff policy n in
        (match on_retry with
         | Some cb -> cb n status backoff
         | None -> ());
        sleep_seconds backoff;
        attempt (n + 1)
    | Error status -> Error status
  in
  attempt 0

(** Create a simple retry policy with just max attempts *)
let simple ~max_attempts : policy =
  { default_policy with max_attempts }

(** Create an aggressive retry policy for critical operations *)
let aggressive : policy = {
  max_attempts = 5;
  initial_backoff = 0.05;     (* 50ms *)
  max_backoff = 2.0;          (* 2 seconds *)
  backoff_multiplier = 1.5;
  retryable_codes = [
    Grpc_core.Status.Unavailable;
    Grpc_core.Status.Resource_exhausted;
    Grpc_core.Status.Aborted;
    Grpc_core.Status.Deadline_exceeded;
  ];
  jitter = 0.3;
}

(** Create a conservative retry policy to minimize load *)
let conservative : policy = {
  max_attempts = 2;
  initial_backoff = 0.5;      (* 500ms *)
  max_backoff = 5.0;          (* 5 seconds *)
  backoff_multiplier = 3.0;
  retryable_codes = [
    Grpc_core.Status.Unavailable;
  ];
  jitter = 0.1;
}

(** Retry budget tracker to prevent retry storms.

    Limits the total number of retries across all calls within a time window. *)
module Budget = struct
  type t = {
    mutable remaining : int;
    mutable last_refill : float;
    refill_interval : float;  (* seconds *)
    max_budget : int;
  }

  let create ?(refill_interval = 10.0) ?(max_budget = 100) () : t = {
    remaining = max_budget;
    last_refill = Unix.gettimeofday ();
    refill_interval;
    max_budget;
  }

  let try_acquire (budget : t) : bool =
    let now = Unix.gettimeofday () in
    (* Refill if interval has passed *)
    if now -. budget.last_refill >= budget.refill_interval then begin
      budget.remaining <- budget.max_budget;
      budget.last_refill <- now
    end;
    if budget.remaining > 0 then begin
      budget.remaining <- budget.remaining - 1;
      true
    end else
      false

  let remaining (budget : t) : int = budget.remaining
end

(** Retry with budget tracking *)
let with_budget
    ?(policy = default_policy)
    ~(budget : Budget.t)
    (f : unit -> ('a, Grpc_core.Status.t) result)
  : ('a, Grpc_core.Status.t) result =
  let rec attempt n =
    match f () with
    | Ok v -> Ok v
    | Error status when n < policy.max_attempts - 1
                     && is_retryable policy status.code
                     && Budget.try_acquire budget ->
        let backoff = calculate_backoff policy n in
        sleep_seconds backoff;
        attempt (n + 1)
    | Error status -> Error status
  in
  attempt 0
