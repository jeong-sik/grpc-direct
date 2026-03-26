(** Shared types and exceptions for the connection subsystem.

    Defined separately to avoid circular dependencies between
    {!Connection}, {!Connection_reader}, and {!Connection_writer}. *)

(** Connection-level protocol error with HTTP/2 error code and message. *)
exception Connection_error of int32 * string
