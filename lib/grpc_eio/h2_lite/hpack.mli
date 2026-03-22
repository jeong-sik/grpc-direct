(** HPACK: Header Compression for HTTP/2 (RFC 7541)

    Encoder and decoder for HTTP/2 header compression. Maintains a dynamic
    table per connection direction (one for encoding, one for decoding).

    Static table: 61 predefined header name-value pairs (RFC 7541 Appendix A).
    Dynamic table: connection-specific headers with FIFO eviction.
    Huffman coding: optional entropy encoding for string literals. *)

(** {1 Types} *)

(** Dynamic table entry. *)
type entry =
  { name : string
  ; value : string
  ; size : int  (** RFC 7541: size = len(name) + len(value) + 32 *)
  }

(** HPACK encoder/decoder context. Each HTTP/2 connection uses two contexts:
    one for encoding outgoing headers, one for decoding incoming headers. *)
type t =
  { mutable dynamic_table : entry list  (** Newest first *)
  ; mutable table_size : int  (** Current size in bytes *)
  ; mutable table_len : int  (** Cached length for O(1) access *)
  ; mutable max_size : int  (** Max size, default 4096 *)
  }

(** {1 Static table} *)

(** The 61 predefined header name-value pairs from RFC 7541 Appendix A.
    Indexed 0-60 (0-based); HPACK wire format uses 1-based indices. *)
val static_table : (string * string) array

(** Number of entries in the static table (61). *)
val static_table_size : int

(** {1 Context management} *)

(** [create ?max_size ()] returns a new HPACK context.
    [max_size] is the dynamic table capacity in bytes (default 4096,
    per SETTINGS_HEADER_TABLE_SIZE). *)
val create : ?max_size:int -> unit -> t

(** [set_max_size t new_size] updates the dynamic table size limit and
    evicts entries as needed. Typically called when a SETTINGS frame changes
    HEADER_TABLE_SIZE.
    @raise Invalid_argument if [new_size] is negative. *)
val set_max_size : t -> int -> unit

(** [add_entry ?debug t name value] inserts a new entry at the front of
    the dynamic table and evicts oldest entries if the table exceeds
    [max_size]. *)
val add_entry : ?debug:bool -> t -> string -> string -> unit

(** {1 Size calculation} *)

(** [entry_size name value] returns the HPACK entry size per RFC 7541
    Section 4.1: [String.length name + String.length value + 32]. *)
val entry_size : string -> string -> int

(** [header_list_size headers] returns the total size of [headers] as
    defined by RFC 7540 Section 10.5. Used for
    SETTINGS_MAX_HEADER_LIST_SIZE checks. *)
val header_list_size : (string * string) list -> int

(** {1 Table lookup} *)

(** [lookup_static_name name] returns the 1-based static table index
    for [name], or [None] if not present. *)
val lookup_static_name : string -> int option

(** [lookup_static name value] returns the 1-based static table index
    for an exact name-value match, or [None]. Only non-empty values are
    indexed. *)
val lookup_static : string -> string -> int option

(** [lookup_dynamic t name value] returns the 1-based index (offset by
    static table size) for an exact match in the dynamic table, or
    [None]. *)
val lookup_dynamic : t -> string -> string -> int option

(** [lookup t name value] searches both static and dynamic tables,
    returning the 1-based index or [None]. *)
val lookup : t -> string -> string -> int option

(** {1 Integer coding (RFC 7541 Section 5.1)} *)

(** [decode_integer buf ~offset ~prefix_bits] decodes a variable-length
    integer from [buf] starting at [offset], using [prefix_bits] bits
    of the first byte. Returns [(value, next_offset)]. *)
val decode_integer : Cstruct.t -> offset:int -> prefix_bits:int -> int * int

(** [encode_integer_with_prefix buf ~offset ~prefix_byte ~prefix_bits ~value]
    encodes [value] into [buf] at [offset], OR-ing [prefix_byte] into the
    first byte. Returns the next offset. *)
val encode_integer_with_prefix
  :  Cstruct.t
  -> offset:int
  -> prefix_byte:int
  -> prefix_bits:int
  -> value:int
  -> int

(** [encode_integer buf ~offset ~prefix_bits ~value] encodes [value]
    with a zero prefix byte. Legacy wrapper around
    {!encode_integer_with_prefix}. *)
val encode_integer : Cstruct.t -> offset:int -> prefix_bits:int -> value:int -> int

(** {1 String coding (RFC 7541 Section 5.2)} *)

(** [decode_string buf ~offset] decodes a string literal (plain or
    Huffman-encoded) from [buf]. Returns [(decoded_string, next_offset)].
    @raise Invalid_argument on invalid Huffman encoding. *)
val decode_string : Cstruct.t -> offset:int -> string * int

(** [encode_string buf ~offset str] encodes [str] into [buf] at [offset],
    using Huffman coding when it produces a shorter result. Returns the
    next offset. *)
val encode_string : Cstruct.t -> offset:int -> string -> int

(** {1 Internal helpers (exposed for testing)} *)

(** [remove_last lst] removes the last element of [lst].
    Returns [(Some removed, rest)] or [(None, [])] for empty lists.
    O(n) -- only used during eviction. *)
val remove_last : 'a list -> 'a option * 'a list

(** {1 Dynamic table access} *)

(** [get_dynamic_entry t idx] returns the dynamic table entry at 1-based
    HPACK index [idx] (which must be > static_table_size).
    @raise Invalid_argument if [idx] is out of range. *)
val get_dynamic_entry : t -> int -> entry

(** {1 Header block encoding and decoding} *)

(** [decode t buf] decodes an HPACK-encoded header block from [buf].
    Updates the dynamic table as specified by the block.
    @raise Invalid_argument on invalid HPACK data (bad index, invalid
    Huffman, size update after headers, etc.). *)
val decode : t -> Cstruct.t -> (string * string) list

(** [encode t headers] encodes [headers] into an HPACK block.
    Uses indexed representation where possible and adds new entries
    to the dynamic table. *)
val encode : t -> (string * string) list -> Cstruct.t

(** {1 gRPC header helpers} *)

(** [grpc_request_headers ~authority ~path] returns standard gRPC request
    headers (POST, http, content-type, te). *)
val grpc_request_headers : authority:string -> path:string -> (string * string) list

(** [grpc_response_headers ()] returns [:status 200] and
    [content-type application/grpc]. *)
val grpc_response_headers : unit -> (string * string) list

(** [grpc_trailers ?message status] returns gRPC trailer headers.
    Uses pre-allocated lists for common status codes (0, 1, 2)
    when [message] is empty. *)
val grpc_trailers : ?message:string -> int -> (string * string) list

(** {1 Pre-encoded fast paths} *)

(** [encode_response_headers_fast ()] returns pre-encoded HPACK bytes for
    [:status 200, content-type application/grpc]. Avoids per-request
    encoding overhead. *)
val encode_response_headers_fast : unit -> Cstruct.t

(** [encode_trailers_fast status] returns pre-encoded HPACK bytes for
    [grpc-status] trailers. Uses a pre-built buffer for status 0;
    falls back to dynamic encoding for other codes. *)
val encode_trailers_fast : int -> Cstruct.t

(** {1 Huffman coding} *)

(** Huffman encoding and decoding per RFC 7541 Appendix B. *)
module Huffman : sig
  (** The Huffman code table: [(code, bit_length)] for each byte 0-255.
      Entry 256 is the EOS symbol (0x3fffffff, 30 bits). *)
  val table : (int * int) array

  (** [decode encoded] decodes a Huffman-encoded byte string.
      @raise Invalid_argument on invalid padding or undecodable input. *)
  val decode : string -> string

  (** [encode str] encodes [str] using the HPACK Huffman table.
      Pads incomplete final bytes with EOS prefix (all 1s). *)
  val encode : string -> string
end
