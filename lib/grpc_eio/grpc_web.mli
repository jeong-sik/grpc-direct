(** gRPC-Web framing and base64 utilities.

    gRPC-Web frames are compatible with gRPC message framing, except that
    trailers are appended as a final frame with the MSB set (0x80).

    - Data frame: 1 byte flags (0x00 or 0x01 for compression) + 4-byte length
    - Trailer frame: 1 byte flags (0x80) + 4-byte length + "k: v\r\n" payload *)

(** gRPC-Web transport mode *)
type mode =
  | Binary (** application/grpc-web(+proto) *)
  | Text (** application/grpc-web-text(+proto), base64-encoded *)

(** gRPC-Web frame type.
    For Message, the payload is a full gRPC frame (compressed flag + length + message). *)
type frame =
  | Message of string
  | Trailers of (string * string) list

(** Content-Type for a mode *)
val content_type : mode -> string

(** Parse Content-Type into gRPC-Web mode *)
val mode_of_content_type : string -> (mode, string) result

(** Percent-encode a string for grpc-message headers *)
val percent_encode : string -> string

(** Percent-decode a string from grpc-message headers *)
val percent_decode : string -> (string, string) result

(** Encode trailers as "k: v\r\n" payload *)
val encode_trailers : (string * string) list -> string

(** Decode trailers payload into header list *)
val decode_trailers : string -> (string * string) list

(** Encode a gRPC-Web frame into bytes *)
val encode_frame : frame -> string

(** Decode as many frames as possible, returning frames + remainder *)
val decode_frames_partial : string -> (frame list * string, string) result

(** Decode all frames, error if remainder is non-empty *)
val decode_frames_complete : string -> (frame list, string) result

(** Base64 utilities for gRPC-Web text mode *)
module Base64 : sig
  val encode : string -> string
  val decode : string -> (string, string) result

  module Stream : sig
    type enc_state

    val enc_init : enc_state
    val encode_chunk : enc_state -> string -> string * enc_state
    val encode_final : enc_state -> string

    type dec_state

    val dec_init : dec_state
    val decode_chunk : dec_state -> string -> (string * dec_state, string) result
    val decode_final : dec_state -> (string, string) result
  end
end
