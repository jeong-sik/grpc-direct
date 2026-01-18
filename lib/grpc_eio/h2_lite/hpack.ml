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

(** Static table (RFC 7541 Appendix A) - first 20 most used *)
let static_table = [|
  (* 1-10 *)
  (":authority", "");
  (":method", "GET");
  (":method", "POST");
  (":path", "/");
  (":path", "/index.html");
  (":scheme", "http");
  (":scheme", "https");
  (":status", "200");
  (":status", "204");
  (":status", "206");
  (* 11-20 *)
  (":status", "304");
  (":status", "400");
  (":status", "404");
  (":status", "500");
  ("accept-charset", "");
  ("accept-encoding", "gzip, deflate");
  ("accept-language", "");
  ("accept-ranges", "");
  ("accept", "");
  ("access-control-allow-origin", "");
  (* 21-30 *)
  ("age", "");
  ("allow", "");
  ("authorization", "");
  ("cache-control", "");
  ("content-disposition", "");
  ("content-encoding", "");
  ("content-language", "");
  ("content-length", "");
  ("content-location", "");
  ("content-range", "");
  (* 31-40 *)
  ("content-type", "");
  ("cookie", "");
  ("date", "");
  ("etag", "");
  ("expect", "");
  ("expires", "");
  ("from", "");
  ("host", "");
  ("if-match", "");
  ("if-modified-since", "");
  (* 41-50 *)
  ("if-none-match", "");
  ("if-range", "");
  ("if-unmodified-since", "");
  ("last-modified", "");
  ("link", "");
  ("location", "");
  ("max-forwards", "");
  ("proxy-authenticate", "");
  ("proxy-authorization", "");
  ("range", "");
  (* 51-61 *)
  ("referer", "");
  ("refresh", "");
  ("retry-after", "");
  ("server", "");
  ("set-cookie", "");
  ("strict-transport-security", "");
  ("transfer-encoding", "");
  ("user-agent", "");
  ("vary", "");
  ("via", "");
  ("www-authenticate", "");
|]

let static_table_size = Array.length static_table  (* 61 *)

(** Dynamic table entry *)
type entry = {
  name : string;
  value : string;
  size : int;  (* RFC 7541: size = len(name) + len(value) + 32 *)
}

(** HPACK encoder/decoder context *)
type t = {
  mutable dynamic_table : entry list;  (* Newest first *)
  mutable table_size : int;            (* Current size in bytes *)
  mutable table_len : int;             (* Cached length for O(1) access *)
  mutable max_size : int;              (* Max size, default 4096 *)
}

(** Create new HPACK context *)
let create ?(max_size = 4096) () = {
  dynamic_table = [];
  table_size = 0;
  table_len = 0;
  max_size;
}

(** Calculate entry size per RFC 7541 §4.1 *)
let entry_size name value =
  String.length name + String.length value + 32

(** Calculate header list size (RFC 7540 §10.5) *)
let header_list_size headers =
  List.fold_left (fun acc (name, value) -> acc + entry_size name value) 0 headers

(** Remove last element from list - O(n) but only called during eviction *)
let rec remove_last = function
  | [] -> (None, [])
  | [x] -> (Some x, [])
  | x :: xs ->
    let (removed, rest) = remove_last xs in
    (removed, x :: rest)

(** Evict entries until table_size <= max_size *)
let evict t =
  while t.table_size > t.max_size && t.table_len > 0 do
    match remove_last t.dynamic_table with
    | (Some oldest, rest) ->
      t.dynamic_table <- rest;
      t.table_size <- t.table_size - oldest.size;
      t.table_len <- t.table_len - 1
    | (None, _) -> ()
  done

(** Update dynamic table size limit (RFC 7541 §4.2) *)
let set_max_size t new_size =
  if new_size < 0 then
    invalid_arg "HPACK max_size must be non-negative";
  t.max_size <- new_size;
  evict t

(** Add entry to dynamic table *)
let add_entry ?(debug=false) t name value =
  let size = entry_size name value in
  let entry = { name; value; size } in
  t.dynamic_table <- entry :: t.dynamic_table;
  t.table_size <- t.table_size + size;
  t.table_len <- t.table_len + 1;
  if debug then
    Printf.eprintf "[HPACK] add_entry: name=%s value_len=%d size=%d -> table_len=%d table_size=%d\n%!"
      name (String.length value) size t.table_len t.table_size;
  evict t

(** Static table lookup hashtables for O(1) access *)
let static_name_idx : (string, int) Hashtbl.t = Hashtbl.create 64
let static_pair_idx : (string, int) Hashtbl.t = Hashtbl.create 64

let () =
  (* Build name-only index (first occurrence wins) *)
  for idx = static_table_size - 1 downto 0 do
    let (name, _) = static_table.(idx) in
    Hashtbl.replace static_name_idx name (idx + 1)  (* 1-indexed *)
  done;
  (* Build name+value index for exact matches *)
  for idx = 0 to static_table_size - 1 do
    let (name, value) = static_table.(idx) in
    if value <> "" then begin
      let key = name ^ "\x00" ^ value in  (* Null separator *)
      Hashtbl.add static_pair_idx key (idx + 1)
    end
  done

(** Lookup in static table by name only - O(1) *)
let lookup_static_name name =
  Hashtbl.find_opt static_name_idx name

(** Lookup in static table by name and value - O(1) *)
let lookup_static name value =
  if value = "" then None  (* Empty values not indexed *)
  else
    let key = name ^ "\x00" ^ value in
    Hashtbl.find_opt static_pair_idx key

(** Lookup in dynamic table *)
let lookup_dynamic t name value =
  let rec find idx = function
    | [] -> None
    | entry :: rest ->
      if entry.name = name && entry.value = value then
        Some (static_table_size + idx + 1)  (* After static table *)
      else
        find (idx + 1) rest
  in
  find 0 t.dynamic_table

(** Lookup anywhere (static or dynamic) *)
let lookup t name value =
  match lookup_static name value with
  | Some idx -> Some idx
  | None -> lookup_dynamic t name value

(** Decode integer with prefix (RFC 7541 §5.1) *)
let decode_integer buf ~offset ~prefix_bits =
  let prefix_mask = (1 lsl prefix_bits) - 1 in
  let first_byte = Cstruct.get_uint8 buf offset in
  let i = first_byte land prefix_mask in
  if i < prefix_mask then
    (i, offset + 1)
  else
    (* RFC 7541 §5.1: M starts at 0, so multiplier is 2^M = 1, then 128, then 16384, etc. *)
    let rec decode_multi i m off =
      let b = Cstruct.get_uint8 buf off in
      let i = i + (b land 127) * m in
      if b land 128 = 0 then (i, off + 1)
      else decode_multi i (m * 128) (off + 1)
    in
    decode_multi i 1 (offset + 1)  (* FIX: Start with m=1 (2^0), not 128 *)

(** Encode integer with prefix (RFC 7541 §5.1)
    prefix_byte: The high bits to OR with the value (e.g., 0x80 for indexed)
    prefix_bits: Number of bits available for the value (e.g., 7 for indexed)
*)
let encode_integer_with_prefix buf ~offset ~prefix_byte ~prefix_bits ~value =
  let prefix_mask = (1 lsl prefix_bits) - 1 in
  if value < prefix_mask then begin
    (* Value fits in prefix bits - combine with prefix byte *)
    Cstruct.set_uint8 buf offset (prefix_byte lor value);
    offset + 1
  end else begin
    (* Value too large - use multi-byte encoding *)
    Cstruct.set_uint8 buf offset (prefix_byte lor prefix_mask);
    let rec encode_multi v off =
      if v < 128 then begin
        Cstruct.set_uint8 buf off v;
        off + 1
      end else begin
        Cstruct.set_uint8 buf off ((v land 127) lor 128);
        encode_multi (v lsr 7) (off + 1)
      end
    in
    encode_multi (value - prefix_mask) (offset + 1)
  end

(** Legacy encode_integer for decode compatibility *)
let encode_integer buf ~offset ~prefix_bits ~value =
  encode_integer_with_prefix buf ~offset ~prefix_byte:0 ~prefix_bits ~value

(** Huffman encoding/decoding (RFC 7541 Appendix B)
    256-symbol table with variable-length codes (5-30 bits) *)
module Huffman = struct
  (** Huffman code table: (code, bit_length) for each byte 0-255
      Plus EOS symbol (256) = 0x3fffffff, 30 bits *)
  let table = [|
    (* 0-15 *)
    (0x1ff8, 13); (0x7fffd8, 23); (0xfffffe2, 28); (0xfffffe3, 28);
    (0xfffffe4, 28); (0xfffffe5, 28); (0xfffffe6, 28); (0xfffffe7, 28);
    (0xfffffe8, 28); (0xffffea, 24); (0x3ffffffc, 30); (0xfffffe9, 28);
    (0xfffffea, 28); (0x3ffffffd, 30); (0xfffffeb, 28); (0xfffffec, 28);
    (* 16-31 *)
    (0xfffffed, 28); (0xfffffee, 28); (0xfffffef, 28); (0xffffff0, 28);
    (0xffffff1, 28); (0xffffff2, 28); (0x3ffffffe, 30); (0xffffff3, 28);
    (0xffffff4, 28); (0xffffff5, 28); (0xffffff6, 28); (0xffffff7, 28);
    (0xffffff8, 28); (0xffffff9, 28); (0xffffffa, 28); (0xffffffb, 28);
    (* 32-47: space ! double-quote # $ % & single-quote ( ) * + , - . / *)
    (0x14, 6); (0x3f8, 10); (0x3f9, 10); (0xffa, 12);
    (0x1ff9, 13); (0x15, 6); (0xf8, 8); (0x7fa, 11);
    (0x3fa, 10); (0x3fb, 10); (0xf9, 8); (0x7fb, 11);
    (0xfa, 8); (0x16, 6); (0x17, 6); (0x18, 6);
    (* 48-63: 0 1 2 3 4 5 6 7 8 9 : ; < = > ? *)
    (0x0, 5); (0x1, 5); (0x2, 5); (0x19, 6);
    (0x1a, 6); (0x1b, 6); (0x1c, 6); (0x1d, 6);
    (0x1e, 6); (0x1f, 6); (0x5c, 7); (0xfb, 8);
    (0x7ffc, 15); (0x20, 6); (0xffb, 12); (0x3fc, 10);
    (* 64-79: @ A B C D E F G H I J K L M N O *)
    (0x1ffa, 13); (0x21, 6); (0x5d, 7); (0x5e, 7);
    (0x5f, 7); (0x60, 7); (0x61, 7); (0x62, 7);
    (0x63, 7); (0x64, 7); (0x65, 7); (0x66, 7);
    (0x67, 7); (0x68, 7); (0x69, 7); (0x6a, 7);
    (* 80-95: P Q R S T U V W X Y Z [ \ ] ^ _ *)
    (0x6b, 7); (0x6c, 7); (0x6d, 7); (0x6e, 7);
    (0x6f, 7); (0x70, 7); (0x71, 7); (0x72, 7);
    (0xfc, 8); (0x73, 7); (0xfd, 8); (0x1ffb, 13);
    (0x7fff0, 19); (0x1ffc, 13); (0x3ffc, 14); (0x22, 6);
    (* 96-111: ` a b c d e f g h i j k l m n o *)
    (0x7ffd, 15); (0x3, 5); (0x23, 6); (0x4, 5);
    (0x24, 6); (0x5, 5); (0x25, 6); (0x26, 6);
    (0x27, 6); (0x6, 5); (0x74, 7); (0x75, 7);
    (0x28, 6); (0x29, 6); (0x2a, 6); (0x7, 5);
    (* 112-127: p q r s t u v w x y z { | } ~ DEL *)
    (0x2b, 6); (0x76, 7); (0x2c, 6); (0x8, 5);
    (0x9, 5); (0x2d, 6); (0x77, 7); (0x78, 7);
    (0x79, 7); (0x7a, 7); (0x7b, 7); (0x7ffe, 15);
    (0x7fc, 11); (0x3ffd, 14); (0x1ffd, 13); (0xffffffc, 28);
    (* 128-143 - RFC 7541 Appendix B (correct values, max 28 bits) *)
    (0xfffe6, 20); (0x3fffd2, 22); (0xfffe7, 20); (0xfffe8, 20);
    (0x3fffd3, 22); (0x3fffd4, 22); (0x3fffd5, 22); (0x3fffd6, 22);
    (0x3fffd7, 22); (0x3fffd8, 22); (0x3fffd9, 22); (0x3fffda, 22);
    (0x3fffdb, 22); (0x3fffdc, 22); (0x3fffdd, 22); (0x3fffde, 22);
    (* 144-159 *)
    (0xffffeb, 24); (0x3fffdf, 22); (0xffffec, 24); (0xffffed, 24);
    (0x3fffe0, 22); (0x3fffe1, 22); (0x3fffe2, 22); (0xffffee, 24);
    (0x3fffe3, 22); (0x3fffe4, 22); (0x3fffe5, 22); (0x3fffe6, 22);
    (0x3fffe7, 22); (0xffffef, 24); (0x3fffe8, 22); (0x3fffe9, 22);
    (* 160-175 *)
    (0xffffea, 24); (0x3fffea, 22); (0xfffff0, 24); (0x3fffeb, 22);
    (0x3fffec, 22); (0xfffff1, 24); (0xfffff2, 24); (0x3fffed, 22);
    (0x3fffee, 22); (0xfffff3, 24); (0xfffff4, 24); (0xfffff5, 24);
    (0x3fffef, 22); (0x3ffff0, 22); (0x3ffff1, 22); (0x3ffff2, 22);
    (* 176-191 *)
    (0xfffff6, 24); (0x3ffff3, 22); (0x3ffff4, 22); (0x3ffff5, 22);
    (0x3ffff6, 22); (0xfffff7, 24); (0x3ffff7, 22); (0x3ffff8, 22);
    (0x3ffff9, 22); (0xfffff8, 24); (0xfffff9, 24); (0xfffffa, 24);
    (0x3ffffa, 22); (0xfffffb, 24); (0x3ffffb, 22); (0x3ffffc, 22);
    (* 192-207 - RFC 7541 Appendix B (corrected) *)
    (0x3ffffe0, 26); (0x3ffffe1, 26); (0xfffeb, 20); (0x7fff1, 19);
    (0x3fffe7, 22); (0x7ffff2, 23); (0x3fffe8, 22); (0x1ffffec, 25);
    (0x3ffffe2, 26); (0x3ffffe3, 26); (0x3ffffe4, 26); (0x7ffffde, 27);
    (0x7ffffdf, 27); (0x3ffffe5, 26); (0xfffff1, 24); (0x1ffffed, 25);
    (* 208-223 - RFC 7541 Appendix B (corrected) *)
    (0x7fff2, 19); (0x1fffe3, 21); (0x3ffffe6, 26); (0x7ffffe0, 27);
    (0x7ffffe1, 27); (0x3ffffe7, 26); (0x7ffffe2, 27); (0xfffff2, 24);
    (0x1fffe4, 21); (0x1fffe5, 21); (0x3ffffe8, 26); (0x3ffffe9, 26);
    (0xffffffd, 28); (0x7ffffe3, 27); (0x7ffffe4, 27); (0x7ffffe5, 27);
    (* 224-239 - RFC 7541 Appendix B (corrected) *)
    (0xfffec, 20); (0xfffff3, 24); (0xfffed, 20); (0x1fffe6, 21);
    (0x3fffe9, 22); (0x1fffe7, 21); (0x1fffe8, 21); (0x7ffff3, 23);
    (0x3fffea, 22); (0x3fffeb, 22); (0x1ffffee, 25); (0x1ffffef, 25);
    (0xfffff4, 24); (0xfffff5, 24); (0x3ffffea, 26); (0x7ffff4, 23);
    (* 240-255 - RFC 7541 Appendix B (corrected) *)
    (0x3ffffeb, 26); (0x7ffffe6, 27); (0x3ffffec, 26); (0x3ffffed, 26);
    (0x7ffffe7, 27); (0x7ffffe8, 27); (0x7ffffe9, 27); (0x7ffffea, 27);
    (0x7ffffeb, 27); (0xffffffe, 28); (0x7ffffec, 27); (0x7ffffed, 27);
    (0x7ffffee, 27); (0x7ffffef, 27); (0x7fffff0, 27); (0x3ffffee, 26);
  |]

  (** Optimized decode table: (code, len) -> symbol
      Pre-built for O(1) lookup of 5-8 bit codes (most common) *)
  let fast_decode_5 = Array.make 32 (-1)   (* 5-bit codes *)
  let fast_decode_6 = Array.make 64 (-1)   (* 6-bit codes *)
  let fast_decode_7 = Array.make 128 (-1)  (* 7-bit codes *)
  let fast_decode_8 = Array.make 256 (-1)  (* 8-bit codes *)

  (** Reverse lookup for longer codes (10-30 bits): (len << 24 | code) -> symbol
      This replaces O(256) search with O(1) hashtable lookup *)
  let long_code_table : (int, int) Hashtbl.t = Hashtbl.create 256

  let () =
    (* Build ALL lookup tables for O(1) decode *)
    for sym = 0 to 255 do
      let (code, len) = table.(sym) in
      match len with
      | 5 -> fast_decode_5.(code) <- sym
      | 6 -> fast_decode_6.(code) <- sym
      | 7 -> fast_decode_7.(code) <- sym
      | 8 -> fast_decode_8.(code) <- sym
      | _ when len >= 10 && len <= 30 ->
        (* Key: (len << 24) | code - unique per (length, code) pair *)
        let key = (len lsl 24) lor code in
        Hashtbl.add long_code_table key sym
      | _ -> ()
    done

  (** Decode Huffman-encoded bytes (RFC 7541 Appendix B)
      Correctly handles variable-length codes (5-30 bits) by accumulating
      enough bits before attempting to decode.

      Algorithm:
      1. Read bytes incrementally to keep bit buffer under 64 bits
      2. Try to match from shortest code (5 bits) to longest
      3. On match, consume those bits and output the symbol
      4. Continue until all bytes read and bits consumed
  *)
  let decode encoded_bytes =
    let len = String.length encoded_bytes in
    if len = 0 then "" else

    let buf = Buffer.create (len * 2) in

    (* Native int (63 bits on 64-bit OCaml) is sufficient for 56-bit accumulator *)
    let bits = ref 0 in
    let nbits = ref 0 in
    let pos = ref 0 in

    (* Refill accumulator - keep under 56 bits for safe 8-bit additions *)
    let refill () =
      while !nbits < 56 && !pos < len do
        bits := (!bits lsl 8) lor (Char.code encoded_bytes.[!pos]);
        nbits := !nbits + 8;
        incr pos
      done
    in

    refill ();

    (* Decode until we run out of bits (excluding EOS padding) *)
    while !nbits >= 5 do
      let found = ref false in

      (* 5-bit codes - most common (digits, lowercase) *)
      if !nbits >= 5 then begin
        let code = (!bits lsr (!nbits - 5)) land 0x1F in
        let sym = fast_decode_5.(code) in
        if sym >= 0 then begin
          Buffer.add_char buf (Char.unsafe_chr sym);
          nbits := !nbits - 5;
          refill ();
          found := true
        end
      end;

      (* 6-bit codes *)
      if not !found && !nbits >= 6 then begin
        let code = (!bits lsr (!nbits - 6)) land 0x3F in
        let sym = fast_decode_6.(code) in
        if sym >= 0 then begin
          Buffer.add_char buf (Char.unsafe_chr sym);
          nbits := !nbits - 6;
          refill ();
          found := true
        end
      end;

      (* 7-bit codes *)
      if not !found && !nbits >= 7 then begin
        let code = (!bits lsr (!nbits - 7)) land 0x7F in
        let sym = fast_decode_7.(code) in
        if sym >= 0 then begin
          Buffer.add_char buf (Char.unsafe_chr sym);
          nbits := !nbits - 7;
          refill ();
          found := true
        end
      end;

      (* 8-bit codes *)
      if not !found && !nbits >= 8 then begin
        let code = (!bits lsr (!nbits - 8)) land 0xFF in
        let sym = fast_decode_8.(code) in
        if sym >= 0 then begin
          Buffer.add_char buf (Char.unsafe_chr sym);
          nbits := !nbits - 8;
          refill ();
          found := true
        end
      end;

      (* Fast path for longer codes (10-30 bits) using hashtable lookup *)
      if not !found then begin
        let max_code_len = min 30 !nbits in
        let code_len = ref 10 in
        while not !found && !code_len <= max_code_len do
          let shift = !nbits - !code_len in
          let mask = (1 lsl !code_len) - 1 in
          let code = (!bits lsr shift) land mask in

          (* O(1) hashtable lookup *)
          let key = (!code_len lsl 24) lor code in
          (match Hashtbl.find_opt long_code_table key with
          | Some sym ->
            Buffer.add_char buf (Char.unsafe_chr sym);
            nbits := shift;
            refill ();
            found := true
          | None -> ());
          incr code_len
        done
      end;

      (* If still not found, this is EOS padding or error - stop *)
      if not !found then begin
        (* RFC 7541: EOS padding is all 1s, up to 7 bits *)
        if !nbits <= 7 then begin
          let remaining_mask = (1 lsl !nbits) - 1 in
          let remaining = !bits land remaining_mask in
          if remaining = remaining_mask then
            nbits := 0  (* Valid EOS padding *)
          else
            invalid_arg "HPACK invalid Huffman padding"
        end else
          invalid_arg "HPACK invalid Huffman padding"
      end
    done;

    Buffer.contents buf

  (** Encode string to Huffman (RFC 7541 Appendix B) *)
  let encode str =
    let len = String.length str in
    if len = 0 then "" else
    let buf = Buffer.create len in
    let bits = ref 0 in
    let nbits = ref 0 in

    for i = 0 to len - 1 do
      let sym = Char.code str.[i] in
      let (code, code_len) = table.(sym) in
      bits := (!bits lsl code_len) lor code;
      nbits := !nbits + code_len;

      (* Flush complete bytes *)
      while !nbits >= 8 do
        let shift = !nbits - 8 in
        Buffer.add_char buf (Char.chr ((!bits lsr shift) land 0xFF));
        nbits := shift
      done
    done;

    (* Pad with EOS prefix (all 1s) if needed *)
    if !nbits > 0 then begin
      let padding = 8 - !nbits in
      let padded = (!bits lsl padding) lor ((1 lsl padding) - 1) in
      Buffer.add_char buf (Char.chr (padded land 0xFF))
    end;

    Buffer.contents buf
end

(** Decode string literal (RFC 7541 §5.2) *)
let decode_string buf ~offset =
  let first = Cstruct.get_uint8 buf offset in
  let huffman = first land 0x80 <> 0 in
  let (length, off) = decode_integer buf ~offset ~prefix_bits:7 in
  let data = Cstruct.sub buf off length |> Cstruct.to_string in
  let str =
    if huffman && length > 0 then
      (* Huffman-encoded: decode using RFC 7541 Appendix B table *)
      let decoded = Huffman.decode data in
      let reencoded = Huffman.encode decoded in
      if String.length reencoded <> length || reencoded <> data then
        invalid_arg "HPACK invalid Huffman encoding";
      decoded
    else
      (* Literal string: use as-is *)
      data
  in
  (str, off + length)

(** Encode string literal (RFC 7541 §5.2) - use Huffman when smaller *)
let encode_string buf ~offset str =
  let len = String.length str in
  if len = 0 then
    encode_integer_with_prefix buf ~offset ~prefix_byte:0x0 ~prefix_bits:7 ~value:0
  else
    let encoded = Huffman.encode str in
    let encoded_len = String.length encoded in
    let use_huffman = encoded_len < len in
    let prefix_byte = if use_huffman then 0x80 else 0x0 in
    let value_len = if use_huffman then encoded_len else len in
    let off = encode_integer_with_prefix buf ~offset ~prefix_byte ~prefix_bits:7 ~value:value_len in
    if use_huffman then
      Cstruct.blit_from_string encoded 0 buf off encoded_len
    else
      Cstruct.blit_from_string str 0 buf off len;
    off + value_len

(** Safe dynamic table lookup with bounds checking - O(n) for List.nth but cached length *)
let get_dynamic_entry t idx =
  let dyn_idx = idx - static_table_size - 1 in
  if dyn_idx < 0 || dyn_idx >= t.table_len then
    invalid_arg (Printf.sprintf "HPACK invalid dynamic index: %d (dyn_idx=%d, table_len=%d, table_size=%d, max_size=%d)"
      idx dyn_idx t.table_len t.table_size t.max_size)
  else
    List.nth t.dynamic_table dyn_idx

(** Decode header block (RFC 7541 §6) *)
let decode t buf : (string * string) list =
  let headers = ref [] in
  let off = ref 0 in
  let len = Cstruct.length buf in
  let saw_header = ref false in
  let max_size_limit = t.max_size in

  while !off < len do
    let first = Cstruct.get_uint8 buf !off in
    if first land 0x80 <> 0 then begin
      (* Indexed Header Field (§6.1) *)
      let (idx, new_off) = decode_integer buf ~offset:!off ~prefix_bits:7 in
      if idx = 0 then
        invalid_arg "HPACK index 0 is invalid";
      off := new_off;
      let (name, value) =
        if idx <= static_table_size then
          static_table.(idx - 1)
        else
          let entry = get_dynamic_entry t idx in
          (entry.name, entry.value)
      in
      saw_header := true;
      headers := (name, value) :: !headers
    end else if first land 0x40 <> 0 then begin
      (* Literal with Incremental Indexing (§6.2.1) *)
      let (idx, off1) = decode_integer buf ~offset:!off ~prefix_bits:6 in
      let (name, off2) =
        if idx = 0 then
          decode_string buf ~offset:off1
        else if idx <= static_table_size then
          (fst static_table.(idx - 1), off1)
        else
          let entry = get_dynamic_entry t idx in
          (entry.name, off1)
      in
      let (value, off3) = decode_string buf ~offset:off2 in
      off := off3;
      add_entry t name value;
      saw_header := true;
      headers := (name, value) :: !headers
    end else if first land 0x20 <> 0 then begin
      (* Dynamic Table Size Update (§6.3) *)
      if !saw_header then
        invalid_arg "HPACK dynamic table size update after headers";
      let (new_size, new_off) = decode_integer buf ~offset:!off ~prefix_bits:5 in
      if new_size > max_size_limit then
        invalid_arg "HPACK dynamic table size update exceeds SETTINGS_HEADER_TABLE_SIZE";
      off := new_off;
      t.max_size <- new_size;
      evict t
    end else begin
      (* Literal without Indexing (§6.2.2) or Never Indexed (§6.2.3) *)
      let prefix_bits = if first land 0x10 <> 0 then 4 else 4 in
      let (idx, off1) = decode_integer buf ~offset:!off ~prefix_bits in
      let (name, off2) =
        if idx = 0 then
          decode_string buf ~offset:off1
        else if idx <= static_table_size then
          (fst static_table.(idx - 1), off1)
        else
          let entry = get_dynamic_entry t idx in
          (entry.name, off1)
      in
      let (value, off3) = decode_string buf ~offset:off2 in
      off := off3;
      saw_header := true;
      headers := (name, value) :: !headers
    end
  done;
  List.rev !headers

(** Encode headers to HPACK block *)
let encode t headers =
  let buf = Cstruct.create 16384 in  (* Max frame size *)
  let off = ref 0 in

  List.iter (fun (name, value) ->
    match lookup t name value with
    | Some idx ->
      (* Indexed representation (RFC 7541 §6.1): 1xxxxxxx *)
      off := encode_integer_with_prefix buf ~offset:!off
               ~prefix_byte:0x80 ~prefix_bits:7 ~value:idx
    | None ->
      match lookup_static_name name with
      | Some idx ->
        (* Literal with indexing, name indexed (RFC 7541 §6.2.1): 01xxxxxx *)
        let off1 = encode_integer_with_prefix buf ~offset:!off
                     ~prefix_byte:0x40 ~prefix_bits:6 ~value:idx in
        off := encode_string buf ~offset:off1 value;
        add_entry t name value
      | None ->
        (* Literal with indexing, new name: 01000000 + name + value *)
        Cstruct.set_uint8 buf !off 0x40;
        let off1 = encode_string buf ~offset:(!off + 1) name in
        off := encode_string buf ~offset:off1 value;
        add_entry t name value
  ) headers;

  Cstruct.sub buf 0 !off

(** gRPC request headers helper *)
let grpc_request_headers ~authority ~path =
  [
    (":method", "POST");
    (":scheme", "http");
    (":path", path);
    (":authority", authority);
    ("content-type", "application/grpc");
    ("te", "trailers");
  ]

(** gRPC response headers - pre-allocated for zero allocation per request *)
let grpc_response_headers_200 = [
  (":status", "200");
  ("content-type", "application/grpc");
]

let grpc_response_headers () = grpc_response_headers_200

(** gRPC trailers - pre-allocated for common status codes *)
let grpc_trailers_ok = [("grpc-status", "0")]
let grpc_trailers_cancelled = [("grpc-status", "1")]
let grpc_trailers_unknown = [("grpc-status", "2")]

let grpc_trailers ?(message = "") status =
  (* Fast path for common status codes with no message *)
  if message = "" then
    match status with
    | 0 -> grpc_trailers_ok
    | 1 -> grpc_trailers_cancelled
    | 2 -> grpc_trailers_unknown
    | _ -> [("grpc-status", string_of_int status)]
  else
    [("grpc-status", string_of_int status); ("grpc-message", message)]

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
end

(** Encode gRPC response headers (fast path using pre-encoded bytes) *)
let encode_response_headers_fast () = Pre_encoded.response_headers_200

(** Encode gRPC trailers (fast path for status 0) *)
let encode_trailers_fast status =
  if status = 0 then Pre_encoded.trailers_ok
  else
    (* Fallback to dynamic encoding for other status codes *)
    let t = create () in
    encode t (grpc_trailers status)
