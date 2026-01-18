(** gRPC Interceptor chain.

    Interceptors allow cross-cutting concerns like logging, authentication,
    and metrics to be applied to all RPC calls. Inspired by tonic (Rust)
    and grpc-go interceptor patterns.

    {b Thread Safety:}
    - Single-domain safe: Yes
    - Multi-domain safe: Partial
      - Context extensions use Hashtbl (not thread-safe across domains)
      - Stream interceptors with mutable counters need Atomic.t for multi-domain

    {b Unary vs Stream Interceptors:}
    - Unary interceptors wrap request/response pairs
    - Stream interceptors wrap individual messages in a stream

    Example:
    {[
      (* Unary interceptor *)
      let logging = Interceptor.logging ()

      (* Stream interceptor *)
      let stream_log = Interceptor.stream_logging ()

      let server = Server.create ()
        |> Server.with_interceptor logging
        |> Server.with_stream_interceptor stream_log
    ]} *)

(** {1 Context} *)

(** Request context passed through interceptor chain *)
type context = {
  method_ : string;           (** Full method name: /package.Service/Method *)
  metadata : (string * string) list;  (** Request metadata (headers) *)
  deadline : float option;    (** Request deadline (Unix timestamp) *)
  extensions : (string, string) Hashtbl.t;  (** User-defined extensions *)
}

(** Create an empty context *)
val empty_context : method_:string -> unit -> context

(** Create context with metadata *)
val context_with_metadata :
  method_:string ->
  metadata:(string * string) list ->
  ?deadline:float ->
  unit -> context

(** Get extension value from context *)
val get_extension : context -> string -> string option

(** Set extension value in context *)
val set_extension : context -> string -> string -> unit

(** Get metadata value from context *)
val get_metadata : context -> string -> string option

(** Check if deadline has passed *)
val is_deadline_exceeded : context -> bool

(** {1 Unary Interceptors} *)

(** Response from an RPC call *)
type 'a response = {
  value : 'a;
  trailers : (string * string) list;
}

(** Interceptor function type *)
type 'a handler = context -> 'a response

(** Interceptor that wraps a handler *)
type 'a t

(** Create a new interceptor.

    @param name Interceptor name for debugging
    @param f Function that takes context and next handler, returns response *)
val make : name:string -> (context -> (context -> 'a response) -> 'a response) -> 'a t

(** Chain multiple interceptors together.

    Interceptors are applied in order: first interceptor wraps second, etc.
    So [chain [a; b; c] handler] executes as: a -> b -> c -> handler *)
val chain : 'a t list -> 'a handler -> 'a handler

(** Compose two interceptors into one *)
val compose : 'a t -> 'a t -> 'a t

(** {2 Common Unary Interceptors} *)

(** Logging interceptor that prints RPC method and timing *)
val logging : ?log:(string -> unit) -> unit -> _ t

(** Deadline interceptor that checks for deadline exceeded *)
val deadline : unit -> _ t

(** Metadata propagation interceptor *)
val propagate_metadata : string list -> _ t

(** {1 Stream Interceptors} *)

(** Stream interceptor configuration *)
type stream_config = {
  on_message : context -> string -> string;  (** Transform each message *)
  on_complete : context -> unit;             (** Called when stream ends *)
  on_error : context -> exn -> unit;         (** Called on stream error *)
}

(** Default stream config (passthrough) *)
val default_stream_config : stream_config

(** Stream interceptor type *)
type stream_t

(** Create a stream interceptor.

    @param name Interceptor name for debugging
    @param on_message Transform each message (default: passthrough)
    @param on_complete Called when stream completes (default: noop)
    @param on_error Called on stream error (default: noop) *)
val make_stream :
  name:string ->
  ?on_message:(context -> string -> string) ->
  ?on_complete:(context -> unit) ->
  ?on_error:(context -> exn -> unit) ->
  unit -> stream_t

(** Wrap a message stream with interceptor.

    Applies the interceptor's [on_message] to each message read from
    the input stream, writing transformed messages to the output stream.
    Closes [output] when [input] completes. *)
val wrap_stream :
  stream_t ->
  context ->
  input:string Grpc_stream.t ->
  output:string Grpc_stream.t ->
  unit

(** Chain multiple stream interceptors.

    Creates a composite interceptor that applies all interceptors in order. *)
val chain_stream : stream_t list -> stream_t

(** {2 Common Stream Interceptors} *)

(** Logging stream interceptor that logs message count and timing *)
val stream_logging : ?log:(string -> unit) -> unit -> stream_t

(** Metrics stream interceptor that counts messages *)
val stream_metrics : counter:int ref -> unit -> stream_t

(** Validation stream interceptor that checks message size *)
val stream_validate : max_size:int -> unit -> stream_t
