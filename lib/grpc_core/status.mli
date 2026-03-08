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

(** The canonical OK status with empty message and no details. *)
val ok : t

(** Construct an error status.

    @param details Optional detail string.
    @param code The gRPC status code.
    @param message Human-readable error message. *)
val error : ?details:string option -> code -> string -> t

(** [is_ok t] returns [true] when [t.code = OK]. *)
val is_ok : t -> bool

(** Human-readable string: ["CODE: message"]. *)
val to_string : t -> string
