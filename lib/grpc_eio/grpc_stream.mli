(** Close-aware stream wrapper over Eio.Stream. *)

type 'a t
(** Stream of ['a] values that can be explicitly closed. *)

val create : int -> 'a t
(** [create capacity] creates a new stream with the given capacity. *)

val add : 'a t -> 'a -> unit
(** [add t value] adds [value] to [t]. No-op if the stream is closed. *)

val close : 'a t -> unit
(** [close t] marks the stream as closed (non-blocking). Further [add] calls are ignored. *)

val take : 'a t -> 'a
(** [take t] takes the next value from [t].
    Raises [End_of_file] if the stream is closed. *)

val take_nonblocking : 'a t -> 'a option
(** [take_nonblocking t] returns [Some v] if a value is available,
    or [None] if the stream is empty or closed. *)

val length : 'a t -> int
(** [length t] returns the number of buffered items. *)

val is_empty : 'a t -> bool
(** [is_empty t] is [true] if [t] has no buffered items. *)

val is_closed : 'a t -> bool
(** [is_closed t] reports whether [close] has been called. *)
