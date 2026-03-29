(** Connection read path - frame parsing and header block reassembly.

    Internal module used by {!Connection}. Functions take individual
    connection fields as parameters to avoid circular dependencies. *)

open Eio.Std

(** Parsed header block with optional priority/push metadata. *)
type header_block =
  { stream_id : int32
  ; end_stream : bool
  ; header_block : Cstruct.t
  ; priority : Frame.priority_info option
  ; promised_stream_id : int32 option
  }

(** Fill the read buffer with data from the network.
    @raise End_of_file when the peer closes. *)
val fill_read_buffer
  :  read_buf:Cstruct.t
  -> read_pos:int ref
  -> flow:Eio.Flow.two_way_ty r
  -> closed:bool ref
  -> mutex:Eio.Mutex.t
  -> unit

(** Read the next frame from the connection.
    Payloads are always copied (safe to hold across reads).
    @raise End_of_file when the peer closes.
    @raise Connection_common.Connection_error on frame size violations. *)
val read_frame
  :  read_buf:Cstruct.t
  -> read_pos:int ref
  -> flow:Eio.Flow.two_way_ty r
  -> closed:bool ref
  -> mutex:Eio.Mutex.t
  -> max_frame_size:int
  -> last_stream_id_ref:int32 ref
  -> Frame.t

(** Read a complete header block, reassembling CONTINUATION frames.
    @param read_frame_fn Function to read the next frame (typically a
      partial application of {!read_frame}).
    @param first_frame Use a previously-read frame as the initial
      HEADERS/PUSH_PROMISE frame.
    @raise Failure on protocol violations. *)
val read_header_block
  :  read_frame_fn:(unit -> Frame.t)
  -> ?first_frame:Frame.t
  -> unit
  -> header_block

(** Receive and validate the HTTP/2 connection preface (server side).
    @raise Failure if the preface is invalid. *)
val recv_preface
  :  read_buf:Cstruct.t
  -> read_pos:int ref
  -> flow:Eio.Flow.two_way_ty r
  -> closed:bool ref
  -> mutex:Eio.Mutex.t
  -> connection_preface:string
  -> unit
