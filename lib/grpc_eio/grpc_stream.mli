(** Close-aware stream wrapper over Eio.Stream. *)

(** Stream of ['a] values that can be explicitly closed. *)
type 'a t

(** [create capacity] creates a new stream with the given capacity. *)
val create : int -> 'a t

(** [add t value] adds [value] to [t]. No-op if the stream is closed. *)
val add : 'a t -> 'a -> unit

(** [close t] marks the stream as closed (non-blocking). Further [add] calls are ignored. *)
val close : 'a t -> unit

(** [take t] takes the next value from [t].
    Raises [End_of_file] if the stream is closed. *)
val take : 'a t -> 'a

(** [take_nonblocking t] returns [Some v] if a value is available,
    or [None] if the stream is empty or closed. *)
val take_nonblocking : 'a t -> 'a option

(** [length t] returns the number of buffered items. *)
val length : 'a t -> int

(** [is_empty t] is [true] if [t] has no buffered items. *)
val is_empty : 'a t -> bool

(** [is_closed t] reports whether [close] has been called. *)
val is_closed : 'a t -> bool
