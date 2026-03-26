(** Connection write path - frame serialization and output.

    Internal module used by {!Connection}. Functions take individual
    connection fields as parameters to avoid circular dependencies. *)

open Eio.Std

(** Write a single frame using vectored I/O (header + payload).
    @raise Failure if the connection is closed. *)
val write_frame_direct
  :  write_buf:Cstruct.t
  -> flow:Eio.Flow.two_way_ty r
  -> closed:bool ref
  -> mutex:Eio.Mutex.t
  -> Frame.t
  -> unit

(** Write multiple frames, using a single syscall when possible.
    @raise Failure if the connection is closed. *)
val write_frames_direct
  :  write_buf:Cstruct.t
  -> flow:Eio.Flow.two_way_ty r
  -> closed:bool ref
  -> mutex:Eio.Mutex.t
  -> Frame.t list
  -> unit

(** [true] if the frame is a control frame (stream 0 or control type). *)
val is_control_frame : Frame.t -> bool

(** Start the priority writer fiber. No-op if scheduling is disabled. *)
val start_priority_writer
  :  sw:Eio.Switch.t
  -> write_buf:Cstruct.t
  -> flow:Eio.Flow.two_way_ty r
  -> closed:bool ref
  -> mutex:Eio.Mutex.t
  -> scheduler:Priority_scheduler.t option
  -> scheduler_signal:unit Eio.Stream.t option
  -> unit

(** Write a frame, routing through the priority scheduler when enabled. *)
val write_frame
  :  write_buf:Cstruct.t
  -> flow:Eio.Flow.two_way_ty r
  -> closed:bool ref
  -> mutex:Eio.Mutex.t
  -> scheduler:Priority_scheduler.t option
  -> scheduler_signal:unit Eio.Stream.t option
  -> Frame.t
  -> unit

(** Write multiple frames with priority scheduling support. *)
val write_frames
  :  write_buf:Cstruct.t
  -> flow:Eio.Flow.two_way_ty r
  -> closed:bool ref
  -> mutex:Eio.Mutex.t
  -> scheduler:Priority_scheduler.t option
  -> scheduler_signal:unit Eio.Stream.t option
  -> Frame.t list
  -> unit

(** Write a complete gRPC echo response (HEADERS + DATA + TRAILERS)
    in a single write syscall. *)
val write_echo_response
  :  write_buf:Cstruct.t
  -> flow:Eio.Flow.two_way_ty r
  -> closed:bool ref
  -> mutex:Eio.Mutex.t
  -> stream_id:int32
  -> Cstruct.t
  -> unit

(** Like {!write_echo_response} but piggybacks a connection-level
    WINDOW_UPDATE frame when [window_increment > 0]. *)
val write_echo_response_with_window_update
  :  write_buf:Cstruct.t
  -> flow:Eio.Flow.two_way_ty r
  -> closed:bool ref
  -> mutex:Eio.Mutex.t
  -> stream_id:int32
  -> Cstruct.t
  -> window_increment:int
  -> unit
