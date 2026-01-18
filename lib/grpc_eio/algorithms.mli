(** State-of-the-Art Algorithms for High-Performance gRPC.

    Implements cutting-edge algorithms from systems research:
    - P2C: Google Maglev load balancing
    - Ring Buffer: LMAX Disruptor lock-free queue
    - Adaptive Batching: Netflix Zuul-inspired coalescing
    - Exp Histogram: HdrHistogram percentile tracking
    - Circuit Breaker: Hystrix resilience pattern

    @since 0.4.0
*)


(** {1 Power of Two Choices Load Balancer} *)
module P2C : sig
  type 'a backend
  type 'a t

  (** Create P2C balancer from backends with weights *)
  val create : ('a * float) list -> 'a t

  (** Acquire a backend (increments load) *)
  val acquire : 'a t -> 'a option

  (** Release a backend (decrements load) *)
  val release : 'a t -> 'a -> unit

  (** Report failure on backend *)
  val report_failure : 'a t -> 'a -> unit

  (** Get stats: [(value, load, total_requests, failures)] *)
  val stats : 'a t -> ('a * int * int * int) array
end


(** {1 Lock-free Ring Buffer} *)
module RingBuffer : sig
  type 'a t

  (** Create ring buffer with given capacity (rounded to power of 2) *)
  val create : int -> 'a t

  (** Non-blocking push. Returns false if full *)
  val try_push : 'a t -> 'a -> bool

  (** Non-blocking pop. Returns None if empty *)
  val try_pop : 'a t -> 'a option

  val is_empty : 'a t -> bool
  val is_full : 'a t -> bool
  val size : 'a t -> int
end


(** {1 Adaptive Batching} *)
module AdaptiveBatching : sig
  type config = {
    min_batch_size : int;
    max_batch_size : int;
    max_delay_ms : float;
    target_latency_ms : float;
  }

  val default_config : config

  type 'a t

  val create : ?config:config -> unit -> 'a t

  (** Add item, returns batch if ready to flush *)
  val add : 'a t -> 'a -> 'a list option

  (** Report latency to adapt batch size *)
  val report_latency : 'a t -> float -> unit

  (** Force flush pending items *)
  val flush : 'a t -> 'a list

  (** Stats: (current_batch_size, avg_latency, total_batches) *)
  val stats : 'a t -> (int * float * int)
end


(** {1 Exponential Histogram} *)
module ExpHistogram : sig
  type t

  val create : min_value:float -> max_value:float -> t
  val record : t -> float -> unit

  val percentile : t -> float -> float
  val mean : t -> float
  val p50 : t -> float
  val p90 : t -> float
  val p95 : t -> float
  val p99 : t -> float
  val p999 : t -> float

  val reset : t -> unit
  val print_summary : t -> unit
end


(** {1 Circuit Breaker} *)
module CircuitBreaker : sig
  type state = Closed | Open | HalfOpen

  type config = {
    failure_threshold : int;
    success_threshold : int;
    timeout_ms : float;
    half_open_max : int;
  }

  val default_config : config

  type t

  val create : ?config:config -> unit -> t

  (** Check if request should be allowed *)
  val allow : t -> bool

  val record_success : t -> unit
  val record_failure : t -> unit

  (** Stats: (state_name, allowed, rejected, failures) *)
  val stats : t -> (string * int * int * int)
end
