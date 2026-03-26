(** Huffman encoding/decoding for HPACK (RFC 7541 Appendix B)

    256-symbol table with variable-length codes (5-30 bits).
    Used internally by {!Hpack} for string literal compression. *)

(** The Huffman code table: [(code, bit_length)] for each byte 0-255. *)
val table : (int * int) array

(** [decode encoded] decodes a Huffman-encoded byte string.
    @raise Invalid_argument on invalid padding or undecodable input. *)
val decode : string -> string

(** [encode str] encodes [str] using the HPACK Huffman table.
    Pads incomplete final bytes with EOS prefix (all 1s). *)
val encode : string -> string
