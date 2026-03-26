(** Shared types and exceptions for the connection subsystem. *)

(** Connection-level protocol error with HTTP/2 error code and message. *)
exception Connection_error of int32 * string
