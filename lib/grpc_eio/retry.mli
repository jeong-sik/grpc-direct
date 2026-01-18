(** gRPC Retry Policy implementation.

    Implements retry with exponential backoff and jitter as specified in:
    https://github.com/grpc/proposal/blob/master/A6-client-retries.md

    Usage:
    {[
      let policy = Retry.{
        max_attempts = 3;
        initial_backoff = 0.1;
        max_backoff = 1.0;
        backoff_multiplier = 2.0;
        retryable_codes = [Unavailable; Resource_exhausted];
        jitter = 0.2;
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

(** Default retry policy: 3 attempts, 100ms-1s backoff, 2x multiplier *)
val default_policy : policy

(** Check if a status code is retryable according to policy *)
val is_retryable : policy -> Grpc_core.Status.code -> bool

(** Calculate backoff duration for the given attempt number *)
val calculate_backoff : policy -> int -> float

(** Retry interceptor for client-side retry logic.

    @param policy Retry policy configuration (default: default_policy)
    @param on_retry Optional callback (attempt, code, backoff_seconds) *)
val interceptor :
  ?policy:policy ->
  ?on_retry:(int -> Grpc_core.Status.code -> float -> unit) ->
  unit ->
  string Interceptor.t

(** Result-based retry for explicit error handling.

    @param policy Retry policy configuration
    @param on_retry Optional callback when retry occurs
    @param f The function to retry *)
val with_retry :
  ?policy:policy ->
  ?on_retry:(int -> Grpc_core.Status.t -> float -> unit) ->
  (unit -> ('a, Grpc_core.Status.t) result) ->
  ('a, Grpc_core.Status.t) result

(** Create a simple retry policy with just max attempts *)
val simple : max_attempts:int -> policy

(** Aggressive retry policy for critical operations (5 attempts, faster backoff) *)
val aggressive : policy

(** Conservative retry policy to minimize load (2 attempts, slower backoff) *)
val conservative : policy

(** Retry budget tracker to prevent retry storms *)
module Budget : sig
  (** Budget tracker state *)
  type t

  (** Create a new budget tracker.
      @param refill_interval Time in seconds to refill budget (default: 10s)
      @param max_budget Maximum retry tokens (default: 100) *)
  val create : ?refill_interval:float -> ?max_budget:int -> unit -> t

  (** Try to acquire a retry token. Returns false if budget exhausted. *)
  val try_acquire : t -> bool

  (** Get remaining budget *)
  val remaining : t -> int
end

(** Retry with budget tracking to prevent retry storms *)
val with_budget :
  ?policy:policy ->
  budget:Budget.t ->
  (unit -> ('a, Grpc_core.Status.t) result) ->
  ('a, Grpc_core.Status.t) result
