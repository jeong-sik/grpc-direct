(** gRPC Message Framing over HTTP/2

    gRPC message format (Length-Prefixed-Message):
    +------------------+------------------+-------------------+
    | Compressed (1)   | Message Length   | Message           |
    | 0 = no, 1 = yes  | (4 bytes BE)     | (N bytes)         |
    +------------------+------------------+-------------------+

    Reference: https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md
*)

(** gRPC message header size: 1 byte compressed flag + 4 bytes length *)
let header_size = 5

(** Encode a gRPC message with length prefix *)
let encode ?(compressed = false) body =
  let body_len = Cstruct.length body in
  let buf = Cstruct.create (header_size + body_len) in

  (* Compressed flag: 0 or 1 *)
  Cstruct.set_uint8 buf 0 (if compressed then 1 else 0);

  (* Message length: 4 bytes big-endian *)
  Cstruct.BE.set_uint32 buf 1 (Int32.of_int body_len);

  (* Message body *)
  Cstruct.blit body 0 buf header_size body_len;

  buf

(** Decode a gRPC message from buffer.
    Returns (message_body, remaining_buffer) *)
let decode buf =
  let buf_len = Cstruct.length buf in
  if buf_len < header_size then
    failwith "Incomplete gRPC message header";

  let _compressed = Cstruct.get_uint8 buf 0 in
  let msg_len = Cstruct.BE.get_uint32 buf 1 |> Int32.to_int in

  if buf_len < header_size + msg_len then
    failwith (Printf.sprintf "Incomplete gRPC message body: need %d, have %d"
                (header_size + msg_len) buf_len);

  let body = Cstruct.sub buf header_size msg_len in
  let remaining = Cstruct.sub buf (header_size + msg_len)
                    (buf_len - header_size - msg_len) in
  (body, remaining)

(** Try to decode - returns None if incomplete *)
let try_decode buf =
  let buf_len = Cstruct.length buf in
  if buf_len < header_size then None
  else begin
    let msg_len = Cstruct.BE.get_uint32 buf 1 |> Int32.to_int in
    if buf_len < header_size + msg_len then None
    else begin
      let body = Cstruct.sub buf header_size msg_len in
      let remaining = Cstruct.sub buf (header_size + msg_len)
                        (buf_len - header_size - msg_len) in
      Some (body, remaining)
    end
  end

(** Check if buffer contains a complete message *)
let is_complete buf =
  let buf_len = Cstruct.length buf in
  if buf_len < header_size then false
  else begin
    let msg_len = Cstruct.BE.get_uint32 buf 1 |> Int32.to_int in
    buf_len >= header_size + msg_len
  end

(** Get expected message size from header (for pre-allocation) *)
let expected_size buf =
  if Cstruct.length buf < header_size then None
  else begin
    let msg_len = Cstruct.BE.get_uint32 buf 1 |> Int32.to_int in
    Some (header_size + msg_len)
  end

(** gRPC status codes *)
module Status = struct
  type t =
    | Ok                  (* 0 *)
    | Cancelled           (* 1 *)
    | Unknown             (* 2 *)
    | InvalidArgument     (* 3 *)
    | DeadlineExceeded    (* 4 *)
    | NotFound            (* 5 *)
    | AlreadyExists       (* 6 *)
    | PermissionDenied    (* 7 *)
    | ResourceExhausted   (* 8 *)
    | FailedPrecondition  (* 9 *)
    | Aborted             (* 10 *)
    | OutOfRange          (* 11 *)
    | Unimplemented       (* 12 *)
    | Internal            (* 13 *)
    | Unavailable         (* 14 *)
    | DataLoss            (* 15 *)
    | Unauthenticated     (* 16 *)

  let to_int = function
    | Ok -> 0
    | Cancelled -> 1
    | Unknown -> 2
    | InvalidArgument -> 3
    | DeadlineExceeded -> 4
    | NotFound -> 5
    | AlreadyExists -> 6
    | PermissionDenied -> 7
    | ResourceExhausted -> 8
    | FailedPrecondition -> 9
    | Aborted -> 10
    | OutOfRange -> 11
    | Unimplemented -> 12
    | Internal -> 13
    | Unavailable -> 14
    | DataLoss -> 15
    | Unauthenticated -> 16

  let of_int = function
    | 0 -> Ok
    | 1 -> Cancelled
    | 2 -> Unknown
    | 3 -> InvalidArgument
    | 4 -> DeadlineExceeded
    | 5 -> NotFound
    | 6 -> AlreadyExists
    | 7 -> PermissionDenied
    | 8 -> ResourceExhausted
    | 9 -> FailedPrecondition
    | 10 -> Aborted
    | 11 -> OutOfRange
    | 12 -> Unimplemented
    | 13 -> Internal
    | 14 -> Unavailable
    | 15 -> DataLoss
    | 16 -> Unauthenticated
    | _ -> Unknown

  let to_string = function
    | Ok -> "OK"
    | Cancelled -> "CANCELLED"
    | Unknown -> "UNKNOWN"
    | InvalidArgument -> "INVALID_ARGUMENT"
    | DeadlineExceeded -> "DEADLINE_EXCEEDED"
    | NotFound -> "NOT_FOUND"
    | AlreadyExists -> "ALREADY_EXISTS"
    | PermissionDenied -> "PERMISSION_DENIED"
    | ResourceExhausted -> "RESOURCE_EXHAUSTED"
    | FailedPrecondition -> "FAILED_PRECONDITION"
    | Aborted -> "ABORTED"
    | OutOfRange -> "OUT_OF_RANGE"
    | Unimplemented -> "UNIMPLEMENTED"
    | Internal -> "INTERNAL"
    | Unavailable -> "UNAVAILABLE"
    | DataLoss -> "DATA_LOSS"
    | Unauthenticated -> "UNAUTHENTICATED"
end
