(** gRPC Interceptor chain.

    Interceptors allow cross-cutting concerns like logging, authentication,
    and metrics to be applied to all RPC calls. Inspired by tonic (Rust)
    and grpc-go interceptor patterns.

    Example usage:
    {[
      let logging_interceptor = Interceptor.make ~name:"logging" (fun ctx next ->
        Eio.traceln "Starting RPC: %s" ctx.method_;
        let result = next ctx in
        Eio.traceln "Completed RPC: %s" ctx.method_;
        result
      )

      let server = Server.create config
        |> Server.with_interceptor logging_interceptor
        |> Server.with_interceptor auth_interceptor
    ]} *)

(** Request context passed through interceptor chain *)
type context = {
  method_ : string;           (** Full method name: /package.Service/Method *)
  metadata : (string * string) list;  (** Request metadata (headers) *)
  deadline : float option;    (** Request deadline (Unix timestamp) *)
  extensions : (string, string) Hashtbl.t;  (** User-defined extensions *)
}

(** Response from an RPC call *)
type 'a response = {
  value : 'a;
  trailers : (string * string) list;
}

(** Interceptor function type *)
type 'a handler = context -> 'a response

(** Interceptor that wraps a handler *)
type 'a t = {
  name : string;
  intercept : 'a handler -> 'a handler;
}

(** Create a new interceptor.

    @param name Interceptor name for debugging
    @param f Function that takes context and next handler, returns response *)
let make ~name f : _ t =
  { name;
    intercept = (fun next ctx -> f ctx (fun c -> next c))
  }

(** Create an empty context *)
let empty_context ~method_ () : context =
  { method_;
    metadata = [];
    deadline = None;
    extensions = Hashtbl.create 16;
  }

(** Create context with metadata *)
let context_with_metadata ~method_ ~metadata ?deadline () : context =
  { method_;
    metadata;
    deadline;
    extensions = Hashtbl.create 16;
  }

(** Chain multiple interceptors together.

    Interceptors are applied in order: first interceptor wraps second, etc.
    So [chain [a; b; c] handler] executes as: a -> b -> c -> handler *)
let chain (interceptors : 'a t list) (handler : 'a handler) : 'a handler =
  List.fold_right (fun i h -> i.intercept h) interceptors handler

(** Compose two interceptors into one *)
let compose (outer : 'a t) (inner : 'a t) : 'a t =
  { name = outer.name ^ "+" ^ inner.name;
    intercept = (fun h -> outer.intercept (inner.intercept h))
  }

(** Get extension value from context *)
let get_extension (ctx : context) (key : string) : string option =
  Hashtbl.find_opt ctx.extensions key

(** Set extension value in context *)
let set_extension (ctx : context) (key : string) (value : string) : unit =
  Hashtbl.replace ctx.extensions key value

(** Get metadata value from context *)
let get_metadata (ctx : context) (key : string) : string option =
  List.assoc_opt key ctx.metadata

(** Check if deadline has passed *)
let is_deadline_exceeded (ctx : context) : bool =
  match ctx.deadline with
  | None -> false
  | Some deadline -> Unix.gettimeofday () > deadline

(** Common interceptors *)

(** Logging interceptor that prints RPC method and timing *)
let logging ?(log = fun s -> print_endline s) () : _ t =
  make ~name:"logging" (fun ctx next ->
    let start = Unix.gettimeofday () in
    log (Printf.sprintf "→ %s" ctx.method_);
    let result = next ctx in
    let elapsed = Unix.gettimeofday () -. start in
    log (Printf.sprintf "← %s (%.3fs)" ctx.method_ elapsed);
    result
  )

(** Deadline interceptor that checks for deadline exceeded *)
let deadline () : _ t =
  make ~name:"deadline" (fun ctx next ->
    if is_deadline_exceeded ctx then
      failwith "Deadline exceeded"
    else
      next ctx
  )

(** Metadata propagation interceptor *)
let propagate_metadata (keys : string list) : _ t =
  make ~name:"propagate_metadata" (fun ctx next ->
    (* Filter metadata to only include specified keys *)
    let filtered =
      List.filter (fun (k, _) -> List.mem k keys) ctx.metadata
    in
    let ctx' = { ctx with metadata = filtered } in
    next ctx'
  )

(** {1 Stream Interceptors}

    Stream interceptors wrap streaming RPCs, allowing interception of
    individual messages in a stream. Follows the grpc-go pattern with
    separate types for server and client streaming.

    {b Server Stream Interceptor}:
    Wraps the stream handler, can intercept messages before/after processing.

    {b Client Stream Interceptor}:
    Wraps the stream creation, can modify request/response streams.

    Example usage:
    {[
      let stream_logging = Interceptor.make_stream ~name:"stream_logging"
        ~on_message:(fun ctx msg ->
          Eio.traceln "Stream message in %s: %d bytes" ctx.method_ (String.length msg);
          msg)
        ~on_complete:(fun ctx ->
          Eio.traceln "Stream completed: %s" ctx.method_)
        ()
    ]} *)

(** Stream interceptor configuration *)
type stream_config = {
  on_message : context -> string -> string;  (** Transform each message *)
  on_complete : context -> unit;             (** Called when stream ends *)
  on_error : context -> exn -> unit;         (** Called on stream error *)
}

(** Default stream config (passthrough) *)
let default_stream_config : stream_config = {
  on_message = (fun _ctx msg -> msg);
  on_complete = (fun _ctx -> ());
  on_error = (fun _ctx _exn -> ());
}

(** Stream interceptor type *)
type stream_t = {
  stream_name : string;
  config : stream_config;
}

(** Create a stream interceptor.

    @param name Interceptor name for debugging
    @param on_message Transform each message (default: passthrough)
    @param on_complete Called when stream completes (default: noop)
    @param on_error Called on stream error (default: noop) *)
let make_stream
    ~name
    ?(on_message = fun _ctx msg -> msg)
    ?(on_complete = fun _ctx -> ())
    ?(on_error = fun _ctx _exn -> ())
    ()
  : stream_t =
  { stream_name = name;
    config = { on_message; on_complete; on_error };
  }

(** Wrap a message stream with interceptor.

    Applies the interceptor's [on_message] to each message read from
    the input stream, writing transformed messages to the output stream. *)
let wrap_stream
    (interceptor : stream_t)
    (ctx : context)
    ~(input : string Grpc_stream.t)
    ~(output : string Grpc_stream.t)
  : unit =
  let rec loop () =
    let msg = Grpc_stream.take input in
    let transformed = interceptor.config.on_message ctx msg in
    Grpc_stream.add output transformed;
    loop ()
  in
  try
    loop ()
  with
  | End_of_file ->
      interceptor.config.on_complete ctx;
      Grpc_stream.close output
  | exn ->
      interceptor.config.on_error ctx exn;
      Grpc_stream.close output;
      raise exn

(** Chain multiple stream interceptors.

    Creates a composite interceptor that applies all interceptors in order. *)
let chain_stream (interceptors : stream_t list) : stream_t =
  match interceptors with
  | [] -> { stream_name = "identity"; config = default_stream_config }
  | [single] -> single
  | first :: rest ->
      let combined_config = {
        on_message = (fun ctx msg ->
          List.fold_left
            (fun m i -> i.config.on_message ctx m)
            (first.config.on_message ctx msg)
            rest
        );
        on_complete = (fun ctx ->
          first.config.on_complete ctx;
          List.iter (fun i -> i.config.on_complete ctx) rest
        );
        on_error = (fun ctx exn ->
          first.config.on_error ctx exn;
          List.iter (fun i -> i.config.on_error ctx exn) rest
        );
      } in
      { stream_name = String.concat "+" (List.map (fun i -> i.stream_name) interceptors);
        config = combined_config;
      }

(** {2 Common Stream Interceptors} *)

(** Logging stream interceptor that logs message count and timing *)
let stream_logging ?(log = fun s -> print_endline s) () : stream_t =
  let count = ref 0 in
  let start_time = ref 0.0 in
  make_stream ~name:"stream_logging"
    ~on_message:(fun ctx msg ->
      if !count = 0 then start_time := Unix.gettimeofday ();
      incr count;
      log (Printf.sprintf "  [%s] message #%d (%d bytes)" ctx.method_ !count (String.length msg));
      msg)
    ~on_complete:(fun ctx ->
      let elapsed = Unix.gettimeofday () -. !start_time in
      log (Printf.sprintf "  [%s] stream complete: %d messages in %.3fs" ctx.method_ !count elapsed))
    ~on_error:(fun ctx exn ->
      log (Printf.sprintf "  [%s] stream error: %s" ctx.method_ (Printexc.to_string exn)))
    ()

(** Metrics stream interceptor that counts messages *)
let stream_metrics ~(counter : int ref) () : stream_t =
  make_stream ~name:"stream_metrics"
    ~on_message:(fun _ctx msg ->
      incr counter;
      msg)
    ()

(** Validation stream interceptor that checks message size *)
let stream_validate ~max_size () : stream_t =
  make_stream ~name:"stream_validate"
    ~on_message:(fun _ctx msg ->
      if String.length msg > max_size then
        failwith (Printf.sprintf "Message too large: %d > %d" (String.length msg) max_size)
      else
        msg)
    ()
