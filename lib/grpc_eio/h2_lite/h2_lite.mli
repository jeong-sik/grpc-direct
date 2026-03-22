(** H2_lite - Minimal HTTP/2 implementation for gRPC (RFC 7540 compliant)

    A gRPC-optimized HTTP/2 implementation providing:
    - HPACK header compression with dynamic table (RFC 7541)
    - Stream state machine per RFC 7540 Section 5.1
    - Flow control per RFC 7540 Section 5.2
    - Eio-native fiber multiplexing

    Typical usage:
    {[
      (* High-level client *)
      let client = H2_lite.Client.connect ~sw ~env ~host ~port () in
      let response = H2_lite.Client.call_unary client ~service ~method_ ~request in
      H2_lite.Client.close client

      (* High-level server *)
      H2_lite.Server.serve ~sw ~env ~port handler
    ]}

    For low-level stream manipulation, use {!open_stream}, {!send_headers},
    {!send_data}, and {!recv_frame} directly. *)

(** {1 Re-exported submodules} *)

module Buffer_pool = Buffer_pool
module Frame = Frame
module Hpack = Hpack
module Stream = Stream
module Flow_control = Flow_control
module Grpc_message = Grpc_message
module Connection = Connection

(** {1 Stream types} *)

(** A stream handle carrying connection state, HPACK codecs, and flow control.
    Fields are exposed so that low-level servers (e.g. echo servers, h2spec
    harness) can construct stream values directly from a [Connection.t]. *)
type stream =
  { conn : Connection.t
  ; id : int32
  ; stream_state : Stream.t
  ; hpack_encoder : Hpack.t
  ; hpack_decoder : Hpack.t
  ; flow_control : Flow_control.t
  }

(** Response payload received via PUSH_PROMISE (RFC 7540 Section 6.6). *)
type push_response =
  { promised_stream_id : int32
  ; request_headers : (string * string) list
  ; response_headers : (string * string) list
  ; response_body : Cstruct.t
  ; trailers : (string * string) list
  }

(** {1 Low-level stream operations} *)

(** [open_stream ~is_client ~hpack_encoder ~hpack_decoder ~flow_control conn]
    allocates the next stream ID on [conn] and returns a new {!stream} handle. *)
val open_stream
  :  is_client:bool
  -> hpack_encoder:Hpack.t
  -> hpack_decoder:Hpack.t
  -> flow_control:Flow_control.t
  -> Connection.t
  -> stream

(** [send_data stream ~end_stream data] sends a DATA frame.
    Checks the flow-control window before sending.
    @raise Failure if the send window is exhausted. *)
val send_data : stream -> end_stream:bool -> Cstruct.t -> unit

(** [send_priority stream priority] sends a PRIORITY frame and updates the
    stream's priority state in the connection. *)
val send_priority : stream -> Frame.priority_info -> unit

(** [send_headers ?priority stream ~end_stream headers] HPACK-encodes
    [headers] and sends one or more HEADERS/CONTINUATION frames.
    Fragments the encoded block when it exceeds the peer's
    SETTINGS_MAX_FRAME_SIZE.
    @raise Invalid_argument if the header list size exceeds the peer's
    SETTINGS_MAX_HEADER_LIST_SIZE. *)
val send_headers
  :  ?priority:Frame.priority_info
  -> stream
  -> end_stream:bool
  -> (string * string) list
  -> unit

(** [send_push_promise stream ~headers] sends a PUSH_PROMISE frame on
    [stream] and returns a new stream handle for the promised response.
    @raise Invalid_argument if push is disabled in local settings. *)
val send_push_promise : stream -> headers:(string * string) list -> stream

(** [handle_connection_frame conn flow_control hpack_encoder frame] processes
    connection-level frames (SETTINGS, PING, WINDOW_UPDATE, GOAWAY) that
    arrive on stream 0. Call this for frames that do not belong to a
    specific stream. *)
val handle_connection_frame
  :  Connection.t
  -> Flow_control.t
  -> Hpack.t
  -> Frame.t
  -> unit

(** [recv_frame ?on_push stream] reads the next frame addressed to [stream].
    Handles connection-level frames and other-stream frames internally by
    looping until a frame matching [stream.id] arrives.
    When [on_push] is provided, incoming PUSH_PROMISE frames are dispatched
    to that callback; otherwise they are cancelled with RST_STREAM. *)
val recv_frame : ?on_push:(push_response -> unit) -> stream -> Frame.t

(** [decode_headers stream frame] HPACK-decodes the payload of a received
    HEADERS frame and validates the header list size against local settings.
    @raise Failure if the decoded size exceeds SETTINGS_MAX_HEADER_LIST_SIZE. *)
val decode_headers : stream -> Frame.t -> (string * string) list

(** [percent_decode s] decodes percent-encoded characters in [s] per
    RFC 3986. Used to decode grpc-message trailer values. *)
val percent_decode : string -> string

(** {1 High-level gRPC client} *)

module Client : sig
  (** Client connection state. Create with {!connect}.
      Fields are exposed for low-level stream manipulation (e.g. extracting
      the connection handle to call {!open_stream} directly). *)
  type t =
    { conn : Connection.t
    ; authority : string
    ; scheme : string
    ; hpack_encoder : Hpack.t
    ; hpack_decoder : Hpack.t
    ; flow_control : Flow_control.t
    ; on_push : (push_response -> unit) option
    }

  (** [connect ?enable_push ?priority_scheduling ?on_push ~sw ~env ~host ~port ()]
      establishes a TCP connection, performs the HTTP/2 handshake, and returns
      a client handle ready for gRPC calls.

      @param enable_push Enable server push (default: [false]).
      @param priority_scheduling Use the priority-based frame writer
        (default: [true]).
      @param on_push Callback for PUSH_PROMISE responses. *)
  val connect
    :  ?enable_push:bool
    -> ?priority_scheduling:bool
    -> ?on_push:(push_response -> unit)
    -> sw:Eio.Switch.t
    -> env:< net : [> [> `Generic ] Eio.Net.ty ] Eio.Net.t ; .. >
    -> host:string
    -> port:int
    -> unit
    -> t

  (** [call_unary t ~service ~method_ ~request] makes a unary gRPC call.
      Sends [request] as a length-prefixed gRPC message, waits for the
      response, and returns the decoded response body.
      @raise Failure on gRPC error status or missing grpc-status trailer. *)
  val call_unary
    :  t
    -> service:string
    -> method_:string
    -> request:Cstruct.t
    -> Cstruct.t

  (** [close t] sends a GOAWAY frame and closes the connection. *)
  val close : t -> unit
end

(** {1 High-level gRPC server} *)

module Server : sig
  (** A request handler receives a stream handle and a decoded request body,
      and returns the response body. *)
  type handler = stream -> Cstruct.t -> Cstruct.t

  (** [serve ?enable_push ?priority_scheduling ~sw ~env ~port handler]
      starts a gRPC server that listens on [port] and dispatches each
      incoming unary request to [handler]. This function does not return
      under normal operation.

      @param enable_push Enable server push (default: [false]).
      @param priority_scheduling Use the priority-based frame writer
        (default: [true]). *)
  val serve
    :  ?enable_push:bool
    -> ?priority_scheduling:bool
    -> sw:Eio.Switch.t
    -> env:< net : [> [> `Generic ] Eio.Net.ty ] Eio.Net.t ; .. >
    -> port:int
    -> handler
    -> 'a
end

(** [init ()] pre-warms the buffer pool. Call once at startup. *)
val init : unit -> unit
