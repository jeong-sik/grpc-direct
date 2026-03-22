(** Connection - Zero-copy I/O layer for HTTP/2.

    Eio-native connection handling with zero-copy reads and vectored writes.
    Manages HTTP/2 connection preface, settings negotiation, frame I/O,
    and optional priority-based scheduling.

    {b Thread Safety:}
    - Read-path fields ([read_buf], [read_pos]): single-reader fiber.
    - Write-path fields ([write_buf]): single-writer fiber.
    - Shared fields ([closed], [goaway_received], [peer_settings],
      [next_stream_id], [last_stream_id]): protected by internal [Eio.Mutex.t].
*)

open Eio.Std

(** {1 Types} *)

(** HTTP/2 connection settings (RFC 7540 Section 6.5). *)
type settings =
  { header_table_size : int
  ; enable_push : bool
  ; max_concurrent_streams : int
  ; initial_window_size : int
  ; max_frame_size : int
  ; max_header_list_size : int
  }

(** Connection state.

    Exposed as a record because sibling modules ([H2_lite], [Server_lite])
    access fields directly for performance (settings, window sizes, stream IDs).
    Shared mutable fields are protected by the internal [mutex]. *)
type t =
  { flow : Eio.Flow.two_way_ty r
  ; mutable read_buf : Cstruct.t
  ; mutable read_pos : int
  ; mutable consumed : int
  ; write_buf : Cstruct.t
  ; mutable next_stream_id : int32
  ; mutable peer_settings : settings
  ; mutable local_settings : settings
  ; mutable closed : bool
  ; mutable goaway_received : bool
  ; mutable last_stream_id : int32
  ; scheduler : Priority_scheduler.t option
  ; scheduler_signal : unit Eio.Stream.t option
  ; mutex : Eio.Mutex.t
  }

(** Parsed header block with optional priority and push metadata.
    Returned by {!read_header_block} after reassembling CONTINUATION frames. *)
type header_block =
  { stream_id : int32
  ; end_stream : bool
  ; header_block : Cstruct.t
  ; priority : Frame.priority_info option
  ; promised_stream_id : int32 option
  }

(** Connection statistics. *)
type stats =
  { streams_opened : int
  ; frames_sent : int
  ; frames_received : int
  ; bytes_sent : int
  ; bytes_received : int
  }

(** {1 Exceptions} *)

(** Protocol-level connection error with HTTP/2 error code and message.
    Raised on frame size violations and other protocol errors. *)
exception Connection_error of int32 * string

(** {1 Predefined Settings} *)

(** RFC 7540 default settings. *)
val default_settings : settings

(** Settings tuned for gRPC workloads (push disabled, larger window). *)
val grpc_settings : settings

(** {1 Constructor} *)

(** Create a connection over an Eio two-way flow.

    @param settings Connection settings (default: {!grpc_settings}).
    @param priority_scheduling Enable priority-based frame scheduling. *)
val create : ?settings:settings -> ?priority_scheduling:bool -> _ Eio.Flow.two_way -> t

(** {1 Handshake} *)

(** Send HTTP/2 connection preface (client side). *)
val send_preface : t -> unit

(** Receive and validate HTTP/2 connection preface (server side).
    @raise Failure if the preface is invalid. *)
val recv_preface : t -> unit

(** Client handshake: send preface and settings, receive server settings.
    @raise Failure if the server does not respond with a SETTINGS frame. *)
val client_handshake : t -> unit

(** Server handshake: receive preface, send settings, receive client settings.
    @raise Failure if the client does not send a valid preface or SETTINGS. *)
val server_handshake : t -> unit

(** {1 Frame I/O} *)

(** Read the next frame from the connection.
    Payloads are always copied (safe to hold across reads).
    @raise End_of_file when the peer closes the connection.
    @raise Connection_error on protocol violations. *)
val read_frame : t -> Frame.t

(** Read a complete header block, reassembling CONTINUATION frames per
    RFC 7540 Section 6.10.

    @param first_frame Use a previously-read frame as the initial
      HEADERS/PUSH_PROMISE frame instead of reading one.
    @raise Failure on protocol violations (wrong frame type, stream mismatch). *)
val read_header_block : ?first_frame:Frame.t -> t -> header_block

(** Write a single frame. Routes through the priority scheduler when enabled. *)
val write_frame : t -> Frame.t -> unit

(** Write multiple frames. Control frames bypass the scheduler;
    data frames are batched per stream for priority scheduling. *)
val write_frames : t -> Frame.t list -> unit

(** {1 Echo Response (Benchmark Path)} *)

(** Write a complete gRPC echo response (HEADERS + DATA + TRAILERS)
    in a single write syscall. Pre-computed frame templates minimize
    allocations. *)
val write_echo_response : t -> stream_id:int32 -> Cstruct.t -> unit

(** Like {!write_echo_response} but piggybacks a connection-level
    WINDOW_UPDATE frame when [window_increment > 0], saving one syscall. *)
val write_echo_response_with_window_update
  :  t
  -> stream_id:int32
  -> Cstruct.t
  -> window_increment:int
  -> unit

(** {1 Control Frames} *)

(** Send a SETTINGS frame with the connection's local settings. *)
val send_settings : t -> unit

(** Send a SETTINGS ACK frame. *)
val send_settings_ack : t -> unit

(** Send a PING frame.
    @param ack Set to [true] to send a PING response (ACK). *)
val send_ping : t -> ack:bool -> Cstruct.t -> unit

(** Send a WINDOW_UPDATE frame.
    @param stream_id Stream to update ([0l] for connection-level). *)
val send_window_update : t -> stream_id:int32 -> increment:int32 -> unit

(** Send a GOAWAY frame and mark the connection as closing.
    @param last_stream_id Highest stream ID the sender processed.
    @param error_code HTTP/2 error code.
    @param debug_data Optional debug payload. *)
val send_goaway
  :  t
  -> last_stream_id:int32
  -> error_code:int32
  -> debug_data:string
  -> unit

(** {1 Settings Management} *)

(** Parse a SETTINGS frame payload into [(id, value)] pairs.
    @raise Failure if the payload length is not a multiple of 6. *)
val parse_settings_payload : Cstruct.t -> (int * int32) list

(** Apply peer SETTINGS to the connection. Thread-safe. *)
val apply_peer_settings : t -> (int * int32) list -> unit

(** Return the peer's current max frame size. Thread-safe. *)
val peer_max_frame_size : t -> int

(** {1 Stream ID Allocation} *)

(** Allocate the next stream ID.
    Client streams are odd, server streams are even (RFC 7540 Section 5.1.1).
    Thread-safe. *)
val next_stream_id : t -> is_client:bool -> int32

(** {1 Priority Scheduling} *)

(** Start the priority writer fiber. Only effective when the connection
    was created with [~priority_scheduling:true].
    Must be called within an Eio switch. *)
val start_priority_writer : sw:Eio.Switch.t -> t -> unit

(** Update stream priority for the scheduler.
    No-op when priority scheduling is disabled. *)
val update_priority : t -> stream_id:int32 -> Frame.priority_info -> unit

(** {1 Lifecycle} *)

(** Close the connection, releasing pooled buffers.
    Thread-safe; idempotent. *)
val close : t -> unit
