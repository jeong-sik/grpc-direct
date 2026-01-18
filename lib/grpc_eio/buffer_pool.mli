(** High-Performance Buffer Pool for Zero-Copy gRPC.

    This module provides thread-safe buffer pooling to eliminate allocation
    overhead in the gRPC hot path. Inspired by best practices from:
    - Rust tonic's `bytes::Bytes`
    - Go's `sync.Pool`
    - Zig's explicit allocators

    {b Usage:}
    {[
      (* Acquire a buffer *)
      let buf = Buffer_pool.acquire 1024 in

      (* Use the buffer... *)
      Bytes.set buf 0 'H';

      (* Release back to pool *)
      Buffer_pool.release buf
    ]}

    @since 0.4.0
*)

(** {1 Core Pool API} *)

(** Acquire a buffer of at least the requested size.
    Returns a pooled buffer if available, or allocates a new one.
    Thread-safe via Domain-local storage. *)
val acquire : int -> Bytes.t

(** Release a buffer back to the pool.
    The buffer must not be used after this call.
    Only buffers of pooled sizes are actually recycled. *)
val release : Bytes.t -> unit

(** Get pool statistics: (size, hits, misses, hit_rate) per size class *)
val stats : unit -> (int * int * int * float) array

(** Print formatted pool statistics to stdout *)
val print_stats : unit -> unit


(** {1 Zero-Copy Slice API} *)

(** A view into a buffer without copying.
    Similar to Rust's `&[u8]` or Go's `[]byte` slice. *)
type slice

(** Create a new slice backed by a pooled buffer.
    @param pooled If true, buffer will be returned to pool on release *)
val slice_create : pooled:bool -> int -> slice

(** Create a slice from a string (copies data into pooled buffer) *)
val slice_of_string : string -> slice

(** Extract string from slice (copies) *)
val slice_to_string : slice -> string

(** Create a sub-slice (zero-copy, shares underlying buffer) *)
val slice_sub : slice -> off:int -> len:int -> slice

(** Release the slice's underlying buffer back to pool *)
val slice_release : slice -> unit

(** Get the length of a slice *)
val slice_length : slice -> int

(** Blit from Bigstringaf into slice (for H2 integration) *)
val slice_blit_from_bigstring :
  src:Bigstringaf.t ->
  src_off:int ->
  slice ->
  dst_off:int ->
  len:int ->
  unit


(** {1 Pooled Message Builder} *)

(** Builder for constructing messages with automatic buffer management.
    Grows as needed and uses pooled buffers internally. *)
module Builder : sig
  type t

  (** Create a new builder with initial capacity *)
  val create : ?capacity:int -> unit -> t

  (** Append a string to the builder *)
  val add_string : t -> string -> unit

  (** Append bytes to the builder *)
  val add_bytes : t -> Bytes.t -> off:int -> len:int -> unit

  (** Append bigstring to the builder (zero-copy into builder's buffer) *)
  val add_bigstring : t -> Bigstringaf.t -> off:int -> len:int -> unit

  (** Get the built contents as a string *)
  val contents : t -> string

  (** Get the built contents as a slice (zero-copy) *)
  val to_slice : t -> slice

  (** Release the builder's buffer *)
  val release : t -> unit
end
