(** gRPC status codes.

    See: {{:https://grpc.github.io/grpc/core/md_doc_statuscodes.html} gRPC Status Codes} *)

(** Standard gRPC status codes. *)
type code =
  | OK
  | Cancelled
  | Unknown
  | Invalid_argument
  | Deadline_exceeded
  | Not_found
  | Already_exists
  | Permission_denied
  | Resource_exhausted
  | Failed_precondition
  | Aborted
  | Out_of_range
  | Unimplemented
  | Internal
  | Unavailable
  | Data_loss
  | Unauthenticated

(** A gRPC status with code, human-readable message, and optional details. *)
type t =
  { code : code
  ; message : string
  ; details : string option
  }

(** Convert a status code to its integer wire representation. *)
val code_to_int : code -> int

(** Convert an integer to a status code. Unknown integers map to [Unknown]. *)
val int_to_code : int -> code

(** Alias for {!int_to_code}. *)
val code_of_int : int -> code

(** Convert a status code to its canonical SCREAMING_SNAKE_CASE name
    (e.g. [OK], [NOT_FOUND], [DEADLINE_EXCEEDED]). *)
val code_to_string : code -> string

(** The canonical OK status with empty message and no details. *)
val ok : t

(** Construct an error status.

    @param details Optional detail string.
    @param code The gRPC status code.
    @param message Human-readable error message. *)
val error : ?details:string -> code -> string -> t

(** [is_ok t] returns [true] when [t.code = OK]. *)
val is_ok : t -> bool

(** Human-readable string: ["CODE: message"]. *)
val to_string : t -> string

(** Exception carrying a typed gRPC status.

    Use this instead of [Failure] to propagate gRPC errors through the
    interceptor chain with full status information (code, message, details).

    {[
      raise (Grpc_error (Status.error Unavailable "server down"))
      (* or equivalently: *)
      Status.raise_error Unavailable "server down"
    ]} *)
exception Grpc_error of t

(** Raise a {!Grpc_error} with the given code and message.

    @param details Optional detail string.
    @raise Grpc_error always. *)
val raise_error : ?details:string -> code -> string -> 'a
