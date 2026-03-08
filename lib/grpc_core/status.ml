(** gRPC status codes.

    See: https://grpc.github.io/grpc/core/md_doc_statuscodes.html *)

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

type t =
  { code : code
  ; message : string
  ; details : string option
  }

let code_to_int = function
  | OK -> 0
  | Cancelled -> 1
  | Unknown -> 2
  | Invalid_argument -> 3
  | Deadline_exceeded -> 4
  | Not_found -> 5
  | Already_exists -> 6
  | Permission_denied -> 7
  | Resource_exhausted -> 8
  | Failed_precondition -> 9
  | Aborted -> 10
  | Out_of_range -> 11
  | Unimplemented -> 12
  | Internal -> 13
  | Unavailable -> 14
  | Data_loss -> 15
  | Unauthenticated -> 16
;;

let int_to_code = function
  | 0 -> OK
  | 1 -> Cancelled
  | 2 -> Unknown
  | 3 -> Invalid_argument
  | 4 -> Deadline_exceeded
  | 5 -> Not_found
  | 6 -> Already_exists
  | 7 -> Permission_denied
  | 8 -> Resource_exhausted
  | 9 -> Failed_precondition
  | 10 -> Aborted
  | 11 -> Out_of_range
  | 12 -> Unimplemented
  | 13 -> Internal
  | 14 -> Unavailable
  | 15 -> Data_loss
  | 16 -> Unauthenticated
  | _ -> Unknown
;;

(** Alias for consistency *)
let code_of_int = int_to_code

let ok = { code = OK; message = ""; details = None }
let error ?details code message = { code; message; details }
let is_ok t = t.code = OK

let to_string t =
  let code_str =
    match t.code with
    | OK -> "OK"
    | Cancelled -> "CANCELLED"
    | Unknown -> "UNKNOWN"
    | Invalid_argument -> "INVALID_ARGUMENT"
    | Deadline_exceeded -> "DEADLINE_EXCEEDED"
    | Not_found -> "NOT_FOUND"
    | Already_exists -> "ALREADY_EXISTS"
    | Permission_denied -> "PERMISSION_DENIED"
    | Resource_exhausted -> "RESOURCE_EXHAUSTED"
    | Failed_precondition -> "FAILED_PRECONDITION"
    | Aborted -> "ABORTED"
    | Out_of_range -> "OUT_OF_RANGE"
    | Unimplemented -> "UNIMPLEMENTED"
    | Internal -> "INTERNAL"
    | Unavailable -> "UNAVAILABLE"
    | Data_loss -> "DATA_LOSS"
    | Unauthenticated -> "UNAUTHENTICATED"
  in
  Printf.sprintf "%s: %s" code_str t.message
;;
