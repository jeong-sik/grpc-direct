(** HPACK static table and lookup (RFC 7541 Appendix A)

    The 61 predefined header name-value pairs. Used internally by {!Hpack}. *)

(** The 61 predefined header name-value pairs.
    Indexed 0-60 (0-based); HPACK wire format uses 1-based indices. *)
val static_table : (string * string) array

(** Number of entries in the static table (61). *)
val static_table_size : int

(** [lookup_name name] returns the 1-based static table index
    for [name], or [None] if not present. *)
val lookup_name : string -> int option

(** [lookup name value] returns the 1-based static table index
    for an exact name-value match, or [None]. Only non-empty values
    are indexed. *)
val lookup : string -> string -> int option
