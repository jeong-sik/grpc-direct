(** Compression codecs for gRPC.

    Provides identity (no-op), gzip, and zstd codecs. Each codec is a pair
    of [encoder] / [decoder] functions that return [Result] on failure. *)

(** An encoder transforms a raw string into its compressed form,
    or returns an error message. *)
type encoder = string -> (string, string) result

(** A decoder transforms a compressed string back to raw form,
    or returns an error message. *)
type decoder = string -> (string, string) result

(** A named compression codec. *)
type t =
  { name : string
  ; encoder : encoder
  ; decoder : decoder
  }

(** Identity codec (no compression). *)
val identity : t

(** Gzip codec using the decompress library.

    @param level Compression level (default: 4). *)
val gzip : ?level:int -> unit -> t

(** Zstd codec.

    @param level Compression level (default: 3). *)
val zstd : ?level:int -> unit -> t

(** Normalize an encoding name (trim whitespace, lowercase). *)
val normalize_name : string -> string

(** Parse a [grpc-accept-encoding] header value into a list of
    normalized encoding names. *)
val parse_accept : string -> string list

(** Find a codec by name in a list of supported codecs. *)
val find_by_name : supported:t list -> string -> t option

(** Negotiate a codec from the [grpc-accept-encoding] header.

    Returns the first supported codec that appears in [accepted],
    or {!identity} if none match. *)
val negotiate : supported:t list -> accepted:string -> t

(** [is_identity codec] returns [true] when [codec.name = "identity"]. *)
val is_identity : t -> bool
