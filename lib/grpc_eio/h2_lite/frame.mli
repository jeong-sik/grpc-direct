(** HTTP/2 Frame Parser - gRPC-specific minimal implementation.

    Implements frame types per RFC 7540 Section 4.1.
    Includes parsing, serialization, and constructors for all standard
    HTTP/2 frame types used by gRPC. *)

(** {1 Types} *)

(** Frame types per RFC 7540 section 6. *)
type frame_type =
  | Data
  | Headers
  | Priority
  | RstStream
  | Settings
  | PushPromise
  | Ping
  | GoAway
  | WindowUpdate
  | Continuation
  | Unknown of int

(** HTTP/2 priority info (RFC 7540 section 5.3). *)
type priority_info =
  { exclusive : bool
  ; dependency : int32
  ; weight : int (** 1-256 *)
  }

(** Parsed frame header (9 bytes). *)
type header =
  { length : int
  ; frame_type : frame_type
  ; flags : int
  ; stream_id : int32
  }

(** Complete frame with payload. *)
type t =
  { header : header
  ; payload : Cstruct.t
  }

(** {1 Constants} *)

(** Frame header size: always 9 bytes. *)
val header_size : int

(** Default max frame size for gRPC (16384). *)
val max_frame_size : int

(** {1 Conversion} *)

val frame_type_of_int : int -> frame_type
val int_of_frame_type : frame_type -> int

(** {1 Frame flags} *)

module Flags : sig
  val end_stream : int
  val end_headers : int
  val padded : int
  val priority : int
  val ack : int

  (** [is_set flags flag] returns [true] if [flag] is set in [flags]. *)
  val is_set : int -> int -> bool
end

(** {1 Parsing} *)

(** Parse frame header from buffer.
    Returns the header and the remaining buffer after the header.
    @raise Invalid_argument if buffer is smaller than {!header_size}. *)
val parse_header : Cstruct.t -> header * Cstruct.t

(** Parse a complete frame from buffer.
    Returns [None] if the buffer does not contain a complete frame. *)
val parse : Cstruct.t -> (t * Cstruct.t) option

(** Parse priority fields from payload (RFC 7540 section 6.3).
    Returns the priority info and the new offset.
    @raise Invalid_argument if payload is too small. *)
val parse_priority : Cstruct.t -> offset:int -> priority_info * int

(** {1 Serialization} *)

(** Write frame header to buffer. Caller must ensure [buf] has at least 9 bytes. *)
val write_header : Cstruct.t -> header -> unit

(** Serialize frame to a new [Cstruct.t]. *)
val to_cstruct : t -> Cstruct.t

(** Serialize frame using a pooled buffer from {!Buffer_pool}. *)
val to_cstruct_pooled : t -> Cstruct.t

(** {1 Frame constructors} *)

val make_data : stream_id:int32 -> end_stream:bool -> Cstruct.t -> t

val make_headers
  :  stream_id:int32
  -> end_stream:bool
  -> end_headers:bool
  -> Cstruct.t
  -> t

(** @raise Invalid_argument if [priority.weight] is outside 1-256. *)
val make_headers_with_priority
  :  stream_id:int32
  -> end_stream:bool
  -> end_headers:bool
  -> priority:priority_info
  -> Cstruct.t
  -> t

(** @raise Invalid_argument if [priority.weight] is outside 1-256. *)
val make_priority : stream_id:int32 -> priority_info -> t

val make_push_promise
  :  stream_id:int32
  -> promised_stream_id:int32
  -> end_headers:bool
  -> Cstruct.t
  -> t

val make_rst_stream : stream_id:int32 -> error_code:int32 -> t
val make_ping : ack:bool -> Cstruct.t -> t
val make_settings : ack:bool -> (int * int32) list -> t
val make_window_update : stream_id:int32 -> increment:int32 -> t
val make_goaway : last_stream_id:int32 -> error_code:int32 -> debug_data:string -> t
val make_continuation : stream_id:int32 -> end_headers:bool -> Cstruct.t -> t

(** {1 Fragmentation} *)

(** Split large header block into HEADERS + CONTINUATION frames.
    @raise Invalid_argument if [max_frame_size] is too small for priority block. *)
val make_headers_fragmented
  :  stream_id:int32
  -> end_stream:bool
  -> ?max_frame_size:int
  -> ?priority:priority_info
  -> Cstruct.t
  -> t list

(** Split PUSH_PROMISE header block into PUSH_PROMISE + CONTINUATION frames.
    @raise Invalid_argument if [max_frame_size] is too small. *)
val make_push_promise_fragmented
  :  stream_id:int32
  -> promised_stream_id:int32
  -> ?max_frame_size:int
  -> Cstruct.t
  -> t list

(** {1 Error codes} *)

module Error_code : sig
  val no_error : int32
  val protocol_error : int32
  val internal_error : int32
  val flow_control_error : int32
  val settings_timeout : int32
  val stream_closed : int32
  val frame_size_error : int32
  val refused_stream : int32
  val cancel : int32
  val compression_error : int32
  val connect_error : int32
  val enhance_your_calm : int32
  val inadequate_security : int32
  val http_1_1_required : int32
end

(** {1 Settings identifiers} *)

module Settings_id : sig
  val header_table_size : int
  val enable_push : int
  val max_concurrent_streams : int
  val initial_window_size : int
  val max_frame_size : int
  val max_header_list_size : int
end
