(** gRPC Metrics collection and exposition.

    Provides metrics collection for gRPC calls including:
    - Call counts (by method, status code)
    - Latency histograms
    - Active call gauges
    - Message sizes

    Usage:
    {[
      let metrics = Metrics.create () in
      let server = Server.create ()
        |> Server.with_metrics metrics
      in
      (* Expose metrics *)
      Metrics.serve_prometheus ~sw ~env metrics
    ]} *)

(** Counter for simple incrementing values *)
module Counter : sig
  type t
  val create : unit -> t
  val inc : t -> unit
  val inc_by : t -> int -> unit
  val get : t -> int
  val reset : t -> unit
end

(** Gauge for values that can go up and down *)
module Gauge : sig
  type t
  val create : unit -> t
  val set : t -> float -> unit
  val inc : t -> unit
  val dec : t -> unit
  val get : t -> float
end

(** Histogram for latency distribution *)
module Histogram : sig
  type t

  (** Default buckets: 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s *)
  val default_buckets : float array

  val create : ?buckets:float array -> unit -> t
  val observe : t -> float -> unit
  val get_count : t -> int
  val get_sum : t -> float
  val get_buckets : t -> (float * int) list
  val reset : t -> unit
end

(** Metrics registry *)
type t

(** Create a new metrics registry *)
val create : unit -> t

(** Record a call start (increments active calls and total) *)
val record_call_start : t -> method_:string -> unit

(** Record a call end with latency and success status *)
val record_call_end :
  t ->
  method_:string ->
  latency_sec:float ->
  success:bool ->
  ?request_size:int ->
  ?response_size:int ->
  unit ->
  unit

(** Server-side metrics interceptor.
    Automatically records call counts, latencies, and errors. *)
val server_interceptor : t -> string Interceptor.t

(** Client-side metrics interceptor.
    Same as server_interceptor for now. *)
val client_interceptor : t -> string Interceptor.t

(** Get uptime in seconds *)
val uptime : t -> float

(** Get total call count *)
val total_calls : t -> int

(** Get total error count *)
val total_errors : t -> int

(** Get error rate (0.0 to 1.0) *)
val error_rate : t -> float

(** Export metrics in Prometheus text format.

    Example output:
    {[
      # HELP grpc_server_uptime_seconds Server uptime in seconds
      # TYPE grpc_server_uptime_seconds gauge
      grpc_server_uptime_seconds 123.456

      # HELP grpc_server_calls_total Total number of gRPC calls
      # TYPE grpc_server_calls_total counter
      grpc_server_calls_total 1000
    ]} *)
val to_prometheus : t -> string

(** Serve Prometheus metrics over HTTP/1.1.

    Defaults to 127.0.0.1:9464 and path "/metrics".
    To bind on a different interface/port, pass an explicit sockaddr.
*)
val serve_prometheus :
  ?addr:Eio.Net.Sockaddr.stream ->
  ?path:string ->
  sw:Eio.Switch.t ->
  env:< net : _ Eio.Net.t; .. > ->
  t ->
  unit

(** Print metrics summary to a log function *)
val log_summary : ?log:(string -> unit) -> t -> unit
