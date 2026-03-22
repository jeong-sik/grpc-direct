(** HTTP/2 Flow Control (RFC 7540 Section 5.2)

    Manages send and receive windows at both connection and stream levels.
    Only DATA frames are subject to flow control. *)

(** Maximum window size (2^31 - 1 per RFC 7540 Section 6.9.1). *)
val max_window_size : int

(** Default initial window size (65535 bytes per RFC 7540 Section 6.9.2). *)
val default_initial_window_size : int

(** Opaque flow control state for a connection, including per-stream windows. *)
type t

(** Create a new flow control state with default initial window sizes. *)
val create : unit -> t

(** [can_send t stream_id size] returns [true] if both the connection window
    and the stream window have capacity for [size] bytes. *)
val can_send : t -> int32 -> int -> bool

(** [wait_for_window t stream_id size] blocks the current Eio fiber until
    both the connection and stream send windows have at least [size] bytes. *)
val wait_for_window : t -> int32 -> int -> unit

(** [consume t stream_id size] subtracts [size] from both the connection
    and stream send windows after sending DATA. *)
val consume : t -> int32 -> int -> unit

(** [update t stream_id increment] applies a WINDOW_UPDATE frame.
    Pass [stream_id = 0l] for connection-level updates.
    @raise Failure if the resulting window exceeds {!max_window_size}. *)
val update : t -> int32 -> int -> unit

(** [consume_recv t stream_id size] decreases the receive window by [size].
    Returns a list of [(stream_id, increment)] pairs indicating WINDOW_UPDATE
    frames that should be sent when the window drops below 50% of initial. *)
val consume_recv : t -> int32 -> int -> (int32 * int) list

(** [update_initial_window_size t new_size] handles a SETTINGS change for
    the initial send window size. Adjusts all existing stream windows by the
    delta and broadcasts to unblock waiting fibers. *)
val update_initial_window_size : t -> int -> unit

(** [update_recv_initial_window_size t new_size] handles a local SETTINGS
    change for the initial receive window size. *)
val update_recv_initial_window_size : t -> int -> unit

(** [remove_stream t stream_id] cleans up per-stream windows when a stream
    is closed or reset. *)
val remove_stream : t -> int32 -> unit

(** [connection_send_window t] returns the current connection-level send
    window size. *)
val connection_send_window : t -> int

(** [stream_send_window t stream_id] returns the send window for [stream_id].
    Creates a default window if one does not exist yet. *)
val stream_send_window : t -> int32 -> int

(** [stream_recv_window t stream_id] returns the receive window for [stream_id].
    Creates a default window if one does not exist yet. *)
val stream_recv_window : t -> int32 -> int

(** [debug_print t] writes connection and stream window sizes to stdout. *)
val debug_print : t -> unit
