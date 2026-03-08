(** gRPC timeout parsing and formatting.

    Timeouts follow the gRPC wire format: 1-8 ASCII digits followed by a
    single unit character ([H], [M], [S], [m], [u], [n]).
    Internally stored as nanoseconds in [int64]. *)

(** A timeout value in nanoseconds. *)
type t = int64

(** {2 Unit multipliers} *)

val ns : int64
val us : int64
val ms : int64
val s : int64
val m : int64
val h : int64

(** {2 Parsing and formatting} *)

(** Parse a [grpc-timeout] header value (e.g. ["30S"]).

    Returns [None] for invalid format, unknown unit, or non-positive value. *)
val parse : string -> t option

(** Format a timeout for the [grpc-timeout] header, choosing the largest
    unit that divides evenly. *)
val to_string : t -> string

(** {2 Conversions} *)

val to_nanoseconds : t -> int64
val to_seconds : t -> float
val to_milliseconds : t -> int
val of_seconds : int -> t
val of_milliseconds : int -> t

(** {2 Defaults} *)

(** Default timeout: 30 seconds. *)
val default : t

(** A very large timeout (~2.5 M hours). *)
val infinite : t
