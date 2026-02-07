(** gRPC message framing.

    gRPC messages are length-prefixed:
    - 1 byte: compressed flag (0 or 1)
    - 4 bytes: message length (big-endian uint32)
    - N bytes: message data

    See: https://grpc.github.io/grpc/core/md_doc_PROTOCOL-HTTP2.html *)

(** Encode a message with length-prefix framing.

    @param codec Compression codec to use
    @param data Raw message data
    @return Ok framed_message or Error message on compression failure *)
let encode ~codec data : (string, string) result =
  match codec.Codec.encoder data with
  | Error e -> Error ("Compression failed: " ^ e)
  | Ok compressed_data ->
    let compressed_flag = if Codec.is_identity codec then '\x00' else '\x01' in
    let len = String.length compressed_data in
    let frame = Bytes.create (5 + len) in
    Bytes.set frame 0 compressed_flag;
    Bytes.set_uint16_be frame 1 (len lsr 16);
    Bytes.set_uint16_be frame 3 (len land 0xFFFF);
    Bytes.blit_string compressed_data 0 frame 5 len;
    Ok (Bytes.to_string frame)
;;

(** Default max message size: 4MB (gRPC default) *)
let default_max_size = 4 * 1024 * 1024

(** Decode a length-prefixed message.

    @param codec Compression codec to use for decompression
    @param max_size Maximum allowed message size (default: 4MB). Prevents DoS attacks.
    @param frame Framed message data
    @return Decoded message or error *)
let decode ?(max_size = default_max_size) ~codec frame =
  if String.length frame < 5
  then Error "Frame too short"
  else (
    let compressed = frame.[0] = '\x01' in
    let len =
      (Char.code frame.[1] lsl 24)
      lor (Char.code frame.[2] lsl 16)
      lor (Char.code frame.[3] lsl 8)
      lor Char.code frame.[4]
    in
    (* Security: Validate message size before allocation to prevent DoS *)
    if len > max_size
    then Error (Printf.sprintf "Message too large: %d bytes (max: %d)" len max_size)
    else if String.length frame < 5 + len
    then Error "Frame incomplete"
    else if compressed && Codec.is_identity codec
    then Error "Compressed flag set but grpc-encoding not set"
    else (
      let data = String.sub frame 5 len in
      if compressed then codec.Codec.decoder data else Ok data))
;;

(** Extraction error types *)
type extract_error =
  | Oversized of int (** Message size exceeded max_size *)
  | Decode_error of string (** Decoding failed *)

(** Extract multiple messages from a buffer.

    @param codec Compression codec
    @param max_size Maximum allowed message size (default: 4MB). Prevents DoS attacks.
    @param buf Buffer containing framed messages
    @return Ok (messages, remaining) or Error with reason.
            Per gRPC spec, oversized messages should return RESOURCE_EXHAUSTED. *)
let extract_all ?(max_size = default_max_size) ~codec buf
  : (string list * string, extract_error) result
  =
  let rec loop acc remaining =
    if String.length remaining < 5
    then Ok (List.rev acc, remaining)
    else (
      let len =
        (Char.code remaining.[1] lsl 24)
        lor (Char.code remaining.[2] lsl 16)
        lor (Char.code remaining.[3] lsl 8)
        lor Char.code remaining.[4]
      in
      (* Security: Reject oversized messages with explicit error *)
      if len > max_size
      then Error (Oversized len)
      else if String.length remaining < 5 + len
      then Ok (List.rev acc, remaining) (* Incomplete frame, wait for more data *)
      else (
        let frame = String.sub remaining 0 (5 + len) in
        let rest = String.sub remaining (5 + len) (String.length remaining - 5 - len) in
        match decode ~max_size ~codec frame with
        | Ok msg -> loop (msg :: acc) rest
        | Error e -> Error (Decode_error e)))
  in
  loop [] buf
;;
