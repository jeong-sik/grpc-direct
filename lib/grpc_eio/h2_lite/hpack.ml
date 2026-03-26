(** HPACK: Header Compression for HTTP/2 (RFC 7541)

    Key concepts:
    - Static Table: 61 predefined header name-value pairs
    - Dynamic Table: Connection-specific headers (FIFO eviction)
    - Huffman Encoding: Optional entropy coding for literals

    gRPC typically uses these headers:
    - :method POST
    - :scheme http/https
    - :path /service/method
    - :authority host:port
    - content-type application/grpc
    - te trailers
    - grpc-encoding identity/gzip
    - grpc-status 0-16
*)

(** Re-export static table from Hpack_static *)
let static_table = Hpack_static.static_table

let static_table_size = Hpack_static.static_table_size

(** Dynamic table entry *)
type entry =
  { name : string
  ; value : string
  ; size : int (* RFC 7541: size = len(name) + len(value) + 32 *)
  }

(** HPACK encoder/decoder context *)
type t =
  { mutable dynamic_table : entry list (* Newest first *)
  ; mutable table_size : int (* Current size in bytes *)
  ; mutable table_len : int (* Cached length for O(1) access *)
  ; mutable max_size : int (* Max size, default 4096 *)
  }

(** Create new HPACK context *)
let create ?(max_size = 4096) () =
  { dynamic_table = []; table_size = 0; table_len = 0; max_size }
;;

(** Calculate entry size per RFC 7541 S4.1 *)
let entry_size name value = String.length name + String.length value + 32

(** Calculate header list size (RFC 7540 S10.5) *)
let header_list_size headers =
  List.fold_left (fun acc (name, value) -> acc + entry_size name value) 0 headers
;;

(** Remove last element from list - O(n) but only called during eviction *)
let rec remove_last = function
  | [] -> None, []
  | [ x ] -> Some x, []
  | x :: xs ->
    let removed, rest = remove_last xs in
    removed, x :: rest
;;

(** Evict entries until table_size <= max_size *)
let evict t =
  while t.table_size > t.max_size && t.table_len > 0 do
    match remove_last t.dynamic_table with
    | Some oldest, rest ->
      t.dynamic_table <- rest;
      t.table_size <- t.table_size - oldest.size;
      t.table_len <- t.table_len - 1
    | None, _ -> ()
  done
;;

(** Update dynamic table size limit (RFC 7541 S4.2) *)
let set_max_size t new_size =
  if new_size < 0 then invalid_arg "HPACK max_size must be non-negative";
  t.max_size <- new_size;
  evict t
;;

(** Add entry to dynamic table *)
let add_entry ?(debug = false) t name value =
  let size = entry_size name value in
  let entry = { name; value; size } in
  t.dynamic_table <- entry :: t.dynamic_table;
  t.table_size <- t.table_size + size;
  t.table_len <- t.table_len + 1;
  if debug
  then
    Log.debug
      "[HPACK] add_entry: name=%s value_len=%d size=%d -> table_len=%d table_size=%d"
      name
      (String.length value)
      size
      t.table_len
      t.table_size;
  evict t
;;

(** Delegate static table lookups to Hpack_static *)
let lookup_static_name = Hpack_static.lookup_name

let lookup_static = Hpack_static.lookup

(** Lookup in dynamic table *)
let lookup_dynamic t name value =
  let rec find idx = function
    | [] -> None
    | entry :: rest ->
      if entry.name = name && entry.value = value
      then Some (static_table_size + idx + 1) (* After static table *)
      else find (idx + 1) rest
  in
  find 0 t.dynamic_table
;;

(** Lookup anywhere (static or dynamic) *)
let lookup t name value =
  match lookup_static name value with
  | Some idx -> Some idx
  | None -> lookup_dynamic t name value
;;

(** Decode integer with prefix (RFC 7541 S5.1) *)
let decode_integer buf ~offset ~prefix_bits =
  let prefix_mask = (1 lsl prefix_bits) - 1 in
  let first_byte = Cstruct.get_uint8 buf offset in
  let i = first_byte land prefix_mask in
  if i < prefix_mask
  then i, offset + 1
  else (
    (* RFC 7541 S5.1: M starts at 0, so multiplier is 2^M = 1, then 128, then 16384, etc. *)
    let rec decode_multi i m off =
      let b = Cstruct.get_uint8 buf off in
      let i = i + (b land 127 * m) in
      if b land 128 = 0 then i, off + 1 else decode_multi i (m * 128) (off + 1)
    in
    decode_multi i 1 (offset + 1))
;;

(** Encode integer with prefix (RFC 7541 S5.1)
    prefix_byte: The high bits to OR with the value (e.g., 0x80 for indexed)
    prefix_bits: Number of bits available for the value (e.g., 7 for indexed)
*)
let encode_integer_with_prefix buf ~offset ~prefix_byte ~prefix_bits ~value =
  let prefix_mask = (1 lsl prefix_bits) - 1 in
  if value < prefix_mask
  then (
    (* Value fits in prefix bits - combine with prefix byte *)
    Cstruct.set_uint8 buf offset (prefix_byte lor value);
    offset + 1)
  else (
    (* Value too large - use multi-byte encoding *)
    Cstruct.set_uint8 buf offset (prefix_byte lor prefix_mask);
    let rec encode_multi v off =
      if v < 128
      then (
        Cstruct.set_uint8 buf off v;
        off + 1)
      else (
        Cstruct.set_uint8 buf off (v land 127 lor 128);
        encode_multi (v lsr 7) (off + 1))
    in
    encode_multi (value - prefix_mask) (offset + 1))
;;

(** Legacy encode_integer for decode compatibility *)
let encode_integer buf ~offset ~prefix_bits ~value =
  encode_integer_with_prefix buf ~offset ~prefix_byte:0 ~prefix_bits ~value
;;

(** Huffman coding - delegate to Hpack_huffman *)
module Huffman = struct
  let table = Hpack_huffman.table
  let decode = Hpack_huffman.decode
  let encode = Hpack_huffman.encode
end

(** Decode string literal (RFC 7541 S5.2) *)
let decode_string buf ~offset =
  let first = Cstruct.get_uint8 buf offset in
  let huffman = first land 0x80 <> 0 in
  let length, off = decode_integer buf ~offset ~prefix_bits:7 in
  let data = Cstruct.sub buf off length |> Cstruct.to_string in
  let str =
    if huffman && length > 0
    then (
      (* Huffman-encoded: decode using RFC 7541 Appendix B table *)
      let decoded = Hpack_huffman.decode data in
      let reencoded = Hpack_huffman.encode decoded in
      if String.length reencoded <> length || reencoded <> data
      then invalid_arg "HPACK invalid Huffman encoding";
      decoded)
    else
      (* Literal string: use as-is *)
      data
  in
  str, off + length
;;

(** Encode string literal (RFC 7541 S5.2) - use Huffman when smaller *)
let encode_string buf ~offset str =
  let len = String.length str in
  if len = 0
  then encode_integer_with_prefix buf ~offset ~prefix_byte:0x0 ~prefix_bits:7 ~value:0
  else (
    let encoded = Hpack_huffman.encode str in
    let encoded_len = String.length encoded in
    let use_huffman = encoded_len < len in
    let prefix_byte = if use_huffman then 0x80 else 0x0 in
    let value_len = if use_huffman then encoded_len else len in
    let off =
      encode_integer_with_prefix buf ~offset ~prefix_byte ~prefix_bits:7 ~value:value_len
    in
    if use_huffman
    then Cstruct.blit_from_string encoded 0 buf off encoded_len
    else Cstruct.blit_from_string str 0 buf off len;
    off + value_len)
;;

(** Safe dynamic table lookup with bounds checking - O(n) for List.nth but cached length *)
let get_dynamic_entry t idx =
  let dyn_idx = idx - static_table_size - 1 in
  if dyn_idx < 0 || dyn_idx >= t.table_len
  then
    invalid_arg
      (Printf.sprintf
         "HPACK invalid dynamic index: %d (dyn_idx=%d, table_len=%d, table_size=%d, \
          max_size=%d)"
         idx
         dyn_idx
         t.table_len
         t.table_size
         t.max_size)
  else List.nth t.dynamic_table dyn_idx
;;

(** Decode header block (RFC 7541 S6) *)
let decode t buf : (string * string) list =
  let headers = ref [] in
  let off = ref 0 in
  let len = Cstruct.length buf in
  let saw_header = ref false in
  let max_size_limit = t.max_size in
  while !off < len do
    let first = Cstruct.get_uint8 buf !off in
    if first land 0x80 <> 0
    then (
      (* Indexed Header Field (S6.1) *)
      let idx, new_off = decode_integer buf ~offset:!off ~prefix_bits:7 in
      if idx = 0 then invalid_arg "HPACK index 0 is invalid";
      off := new_off;
      let name, value =
        if idx <= static_table_size
        then static_table.(idx - 1)
        else (
          let entry = get_dynamic_entry t idx in
          entry.name, entry.value)
      in
      saw_header := true;
      headers := (name, value) :: !headers)
    else if first land 0x40 <> 0
    then (
      (* Literal with Incremental Indexing (S6.2.1) *)
      let idx, off1 = decode_integer buf ~offset:!off ~prefix_bits:6 in
      let name, off2 =
        if idx = 0
        then decode_string buf ~offset:off1
        else if idx <= static_table_size
        then fst static_table.(idx - 1), off1
        else (
          let entry = get_dynamic_entry t idx in
          entry.name, off1)
      in
      let value, off3 = decode_string buf ~offset:off2 in
      off := off3;
      add_entry t name value;
      saw_header := true;
      headers := (name, value) :: !headers)
    else if first land 0x20 <> 0
    then (
      (* Dynamic Table Size Update (S6.3) *)
      if !saw_header then invalid_arg "HPACK dynamic table size update after headers";
      let new_size, new_off = decode_integer buf ~offset:!off ~prefix_bits:5 in
      if new_size > max_size_limit
      then
        invalid_arg "HPACK dynamic table size update exceeds SETTINGS_HEADER_TABLE_SIZE";
      off := new_off;
      t.max_size <- new_size;
      evict t)
    else (
      (* Literal without Indexing (S6.2.2) or Never Indexed (S6.2.3) *)
      let prefix_bits = if first land 0x10 <> 0 then 4 else 4 in
      let idx, off1 = decode_integer buf ~offset:!off ~prefix_bits in
      let name, off2 =
        if idx = 0
        then decode_string buf ~offset:off1
        else if idx <= static_table_size
        then fst static_table.(idx - 1), off1
        else (
          let entry = get_dynamic_entry t idx in
          entry.name, off1)
      in
      let value, off3 = decode_string buf ~offset:off2 in
      off := off3;
      saw_header := true;
      headers := (name, value) :: !headers)
  done;
  List.rev !headers
;;

(** Encode headers to HPACK block *)
let encode t headers =
  let buf = Cstruct.create 16384 in
  (* Max frame size *)
  let off = ref 0 in
  List.iter
    (fun (name, value) ->
       match lookup t name value with
       | Some idx ->
         (* Indexed representation (RFC 7541 S6.1): 1xxxxxxx *)
         off
         := encode_integer_with_prefix
              buf
              ~offset:!off
              ~prefix_byte:0x80
              ~prefix_bits:7
              ~value:idx
       | None ->
         (match lookup_static_name name with
          | Some idx ->
            (* Literal with indexing, name indexed (RFC 7541 S6.2.1): 01xxxxxx *)
            let off1 =
              encode_integer_with_prefix
                buf
                ~offset:!off
                ~prefix_byte:0x40
                ~prefix_bits:6
                ~value:idx
            in
            off := encode_string buf ~offset:off1 value;
            add_entry t name value
          | None ->
            (* Literal with indexing, new name: 01000000 + name + value *)
            Cstruct.set_uint8 buf !off 0x40;
            let off1 = encode_string buf ~offset:(!off + 1) name in
            off := encode_string buf ~offset:off1 value;
            add_entry t name value))
    headers;
  Cstruct.sub buf 0 !off
;;

(** gRPC request headers helper *)
let grpc_request_headers ~authority ~path =
  [ ":method", "POST"
  ; ":scheme", "http"
  ; ":path", path
  ; ":authority", authority
  ; "content-type", "application/grpc"
  ; "te", "trailers"
  ]
;;

(** gRPC response headers - pre-allocated for zero allocation per request *)
let grpc_response_headers_200 = [ ":status", "200"; "content-type", "application/grpc" ]

let grpc_response_headers () = grpc_response_headers_200

(** gRPC trailers - pre-allocated for common status codes *)
let grpc_trailers_ok = [ "grpc-status", "0" ]

let grpc_trailers_cancelled = [ "grpc-status", "1" ]
let grpc_trailers_unknown = [ "grpc-status", "2" ]

let grpc_trailers ?(message = "") status =
  (* Fast path for common status codes with no message *)
  if message = ""
  then (
    match status with
    | 0 -> grpc_trailers_ok
    | 1 -> grpc_trailers_cancelled
    | 2 -> grpc_trailers_unknown
    | _ -> [ "grpc-status", string_of_int status ])
  else [ "grpc-status", string_of_int status; "grpc-message", message ]
;;

(** Pre-encoded HPACK bytes for common gRPC headers.
    This eliminates per-request HPACK encoding overhead. *)
module Pre_encoded = struct
  (* Response headers: :status=200, content-type=application/grpc
     Encoded using indexed representation where possible *)
  let response_headers_200 =
    let buf = Bytes.create 32 in
    (* :status: 200 is static table index 8 -> 0x88 (indexed) *)
    Bytes.set buf 0 (Char.chr 0x88);
    (* content-type: application/grpc
       content-type is static index 31, value is literal
       0x5f = 01011111 = literal with indexing, name index 31 *)
    Bytes.set buf 1 (Char.chr 0x5f);
    (* Value length: 16 bytes for "application/grpc" *)
    Bytes.set buf 2 (Char.chr 16);
    (* Value: application/grpc *)
    Bytes.blit_string "application/grpc" 0 buf 3 16;
    Cstruct.of_bytes ~off:0 ~len:19 buf
  ;;

  (* Trailers: grpc-status=0
     grpc-status is NOT in static table, use literal *)
  let trailers_ok =
    let buf = Bytes.create 16 in
    (* 0x40 = literal with indexing, new name *)
    Bytes.set buf 0 (Char.chr 0x40);
    (* Name length: 11 for "grpc-status" *)
    Bytes.set buf 1 (Char.chr 11);
    Bytes.blit_string "grpc-status" 0 buf 2 11;
    (* Value length: 1 for "0" *)
    Bytes.set buf 13 (Char.chr 1);
    Bytes.set buf 14 '0';
    Cstruct.of_bytes ~off:0 ~len:15 buf
  ;;
end

(** Encode gRPC response headers (fast path using pre-encoded bytes) *)
let encode_response_headers_fast () = Pre_encoded.response_headers_200

(** Encode gRPC trailers (fast path for status 0) *)
let encode_trailers_fast status =
  if status = 0
  then Pre_encoded.trailers_ok
  else (
    (* Fallback to dynamic encoding for other status codes *)
    let t = create () in
    encode t (grpc_trailers status))
;;
