(** gRPC message framing.

    gRPC messages are length-prefixed:
    - 1 byte: compressed flag (0 or 1)
    - 4 bytes: message length (big-endian uint32)
    - N bytes: message data

    See: {{:https://grpc.github.io/grpc/core/md_doc_PROTOCOL-HTTP2.html}
         gRPC HTTP/2 Protocol} *)

(** Encode a message with length-prefix framing.

    @param codec Compression codec to use.
    @param data Raw message data.
    @return [Ok framed_message] or [Error reason] on compression failure. *)
val encode : codec:Codec.t -> string -> (string, string) result

(** Default maximum message size: 4 MB (gRPC default). *)
val default_max_size : int

(** Decode a single length-prefixed message.

    @param max_size Maximum allowed message size (default: 4 MB).
    @param codec Compression codec for decompression.
    @param frame Framed message data (at least 5 bytes).
    @return [Ok payload] or [Error reason]. *)
val decode : ?max_size:int -> codec:Codec.t -> string -> (string, string) result

(** Reason why {!extract_all} failed. *)
type extract_error =
  | Oversized of int (** Message size exceeded [max_size]. *)
  | Decode_error of string (** Decompression or framing error. *)

(** Extract all complete messages from a buffer.

    @param max_size Maximum allowed message size (default: 4 MB).
    @param codec Compression codec.
    @param buf Buffer containing zero or more framed messages.
    @return [Ok (messages, remaining_bytes)] or [Error reason].
            Incomplete trailing frames are returned in [remaining_bytes]. *)
val extract_all
  :  ?max_size:int
  -> codec:Codec.t
  -> string
  -> (string list * string, extract_error) result
