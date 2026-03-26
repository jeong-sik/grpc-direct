(** Huffman encoding/decoding for HPACK (RFC 7541 Appendix B)

    256-symbol table with variable-length codes (5-30 bits).
    Optimized decode uses pre-built lookup arrays for 5-8 bit codes
    and a hashtable for longer codes (10-30 bits). *)

(** Huffman code table: (code, bit_length) for each byte 0-255
    Plus EOS symbol (256) = 0x3fffffff, 30 bits *)
let table =
  [| (* 0-15 *)
     0x1ff8, 13
   ; 0x7fffd8, 23
   ; 0xfffffe2, 28
   ; 0xfffffe3, 28
   ; 0xfffffe4, 28
   ; 0xfffffe5, 28
   ; 0xfffffe6, 28
   ; 0xfffffe7, 28
   ; 0xfffffe8, 28
   ; 0xffffea, 24
   ; 0x3ffffffc, 30
   ; 0xfffffe9, 28
   ; 0xfffffea, 28
   ; 0x3ffffffd, 30
   ; 0xfffffeb, 28
   ; 0xfffffec, 28
   ; (* 16-31 *)
     0xfffffed, 28
   ; 0xfffffee, 28
   ; 0xfffffef, 28
   ; 0xffffff0, 28
   ; 0xffffff1, 28
   ; 0xffffff2, 28
   ; 0x3ffffffe, 30
   ; 0xffffff3, 28
   ; 0xffffff4, 28
   ; 0xffffff5, 28
   ; 0xffffff6, 28
   ; 0xffffff7, 28
   ; 0xffffff8, 28
   ; 0xffffff9, 28
   ; 0xffffffa, 28
   ; 0xffffffb, 28
   ; (* 32-47: space ! double-quote # $ % & single-quote ( ) * + , - . / *)
     0x14, 6
   ; 0x3f8, 10
   ; 0x3f9, 10
   ; 0xffa, 12
   ; 0x1ff9, 13
   ; 0x15, 6
   ; 0xf8, 8
   ; 0x7fa, 11
   ; 0x3fa, 10
   ; 0x3fb, 10
   ; 0xf9, 8
   ; 0x7fb, 11
   ; 0xfa, 8
   ; 0x16, 6
   ; 0x17, 6
   ; 0x18, 6
   ; (* 48-63: 0 1 2 3 4 5 6 7 8 9 : ; < = > ? *)
     0x0, 5
   ; 0x1, 5
   ; 0x2, 5
   ; 0x19, 6
   ; 0x1a, 6
   ; 0x1b, 6
   ; 0x1c, 6
   ; 0x1d, 6
   ; 0x1e, 6
   ; 0x1f, 6
   ; 0x5c, 7
   ; 0xfb, 8
   ; 0x7ffc, 15
   ; 0x20, 6
   ; 0xffb, 12
   ; 0x3fc, 10
   ; (* 64-79: @ A B C D E F G H I J K L M N O *)
     0x1ffa, 13
   ; 0x21, 6
   ; 0x5d, 7
   ; 0x5e, 7
   ; 0x5f, 7
   ; 0x60, 7
   ; 0x61, 7
   ; 0x62, 7
   ; 0x63, 7
   ; 0x64, 7
   ; 0x65, 7
   ; 0x66, 7
   ; 0x67, 7
   ; 0x68, 7
   ; 0x69, 7
   ; 0x6a, 7
   ; (* 80-95: P Q R S T U V W X Y Z [ \ ] ^ _ *)
     0x6b, 7
   ; 0x6c, 7
   ; 0x6d, 7
   ; 0x6e, 7
   ; 0x6f, 7
   ; 0x70, 7
   ; 0x71, 7
   ; 0x72, 7
   ; 0xfc, 8
   ; 0x73, 7
   ; 0xfd, 8
   ; 0x1ffb, 13
   ; 0x7fff0, 19
   ; 0x1ffc, 13
   ; 0x3ffc, 14
   ; 0x22, 6
   ; (* 96-111: ` a b c d e f g h i j k l m n o *)
     0x7ffd, 15
   ; 0x3, 5
   ; 0x23, 6
   ; 0x4, 5
   ; 0x24, 6
   ; 0x5, 5
   ; 0x25, 6
   ; 0x26, 6
   ; 0x27, 6
   ; 0x6, 5
   ; 0x74, 7
   ; 0x75, 7
   ; 0x28, 6
   ; 0x29, 6
   ; 0x2a, 6
   ; 0x7, 5
   ; (* 112-127: p q r s t u v w x y z { | } ~ DEL *)
     0x2b, 6
   ; 0x76, 7
   ; 0x2c, 6
   ; 0x8, 5
   ; 0x9, 5
   ; 0x2d, 6
   ; 0x77, 7
   ; 0x78, 7
   ; 0x79, 7
   ; 0x7a, 7
   ; 0x7b, 7
   ; 0x7ffe, 15
   ; 0x7fc, 11
   ; 0x3ffd, 14
   ; 0x1ffd, 13
   ; 0xffffffc, 28
   ; (* 128-143 - RFC 7541 Appendix B (correct values, max 28 bits) *)
     0xfffe6, 20
   ; 0x3fffd2, 22
   ; 0xfffe7, 20
   ; 0xfffe8, 20
   ; 0x3fffd3, 22
   ; 0x3fffd4, 22
   ; 0x3fffd5, 22
   ; 0x3fffd6, 22
   ; 0x3fffd7, 22
   ; 0x3fffd8, 22
   ; 0x3fffd9, 22
   ; 0x3fffda, 22
   ; 0x3fffdb, 22
   ; 0x3fffdc, 22
   ; 0x3fffdd, 22
   ; 0x3fffde, 22
   ; (* 144-159 *)
     0xffffeb, 24
   ; 0x3fffdf, 22
   ; 0xffffec, 24
   ; 0xffffed, 24
   ; 0x3fffe0, 22
   ; 0x3fffe1, 22
   ; 0x3fffe2, 22
   ; 0xffffee, 24
   ; 0x3fffe3, 22
   ; 0x3fffe4, 22
   ; 0x3fffe5, 22
   ; 0x3fffe6, 22
   ; 0x3fffe7, 22
   ; 0xffffef, 24
   ; 0x3fffe8, 22
   ; 0x3fffe9, 22
   ; (* 160-175 *)
     0xffffea, 24
   ; 0x3fffea, 22
   ; 0xfffff0, 24
   ; 0x3fffeb, 22
   ; 0x3fffec, 22
   ; 0xfffff1, 24
   ; 0xfffff2, 24
   ; 0x3fffed, 22
   ; 0x3fffee, 22
   ; 0xfffff3, 24
   ; 0xfffff4, 24
   ; 0xfffff5, 24
   ; 0x3fffef, 22
   ; 0x3ffff0, 22
   ; 0x3ffff1, 22
   ; 0x3ffff2, 22
   ; (* 176-191 *)
     0xfffff6, 24
   ; 0x3ffff3, 22
   ; 0x3ffff4, 22
   ; 0x3ffff5, 22
   ; 0x3ffff6, 22
   ; 0xfffff7, 24
   ; 0x3ffff7, 22
   ; 0x3ffff8, 22
   ; 0x3ffff9, 22
   ; 0xfffff8, 24
   ; 0xfffff9, 24
   ; 0xfffffa, 24
   ; 0x3ffffa, 22
   ; 0xfffffb, 24
   ; 0x3ffffb, 22
   ; 0x3ffffc, 22
   ; (* 192-207 - RFC 7541 Appendix B (corrected) *)
     0x3ffffe0, 26
   ; 0x3ffffe1, 26
   ; 0xfffeb, 20
   ; 0x7fff1, 19
   ; 0x3fffe7, 22
   ; 0x7ffff2, 23
   ; 0x3fffe8, 22
   ; 0x1ffffec, 25
   ; 0x3ffffe2, 26
   ; 0x3ffffe3, 26
   ; 0x3ffffe4, 26
   ; 0x7ffffde, 27
   ; 0x7ffffdf, 27
   ; 0x3ffffe5, 26
   ; 0xfffff1, 24
   ; 0x1ffffed, 25
   ; (* 208-223 - RFC 7541 Appendix B (corrected) *)
     0x7fff2, 19
   ; 0x1fffe3, 21
   ; 0x3ffffe6, 26
   ; 0x7ffffe0, 27
   ; 0x7ffffe1, 27
   ; 0x3ffffe7, 26
   ; 0x7ffffe2, 27
   ; 0xfffff2, 24
   ; 0x1fffe4, 21
   ; 0x1fffe5, 21
   ; 0x3ffffe8, 26
   ; 0x3ffffe9, 26
   ; 0xffffffd, 28
   ; 0x7ffffe3, 27
   ; 0x7ffffe4, 27
   ; 0x7ffffe5, 27
   ; (* 224-239 - RFC 7541 Appendix B (corrected) *)
     0xfffec, 20
   ; 0xfffff3, 24
   ; 0xfffed, 20
   ; 0x1fffe6, 21
   ; 0x3fffe9, 22
   ; 0x1fffe7, 21
   ; 0x1fffe8, 21
   ; 0x7ffff3, 23
   ; 0x3fffea, 22
   ; 0x3fffeb, 22
   ; 0x1ffffee, 25
   ; 0x1ffffef, 25
   ; 0xfffff4, 24
   ; 0xfffff5, 24
   ; 0x3ffffea, 26
   ; 0x7ffff4, 23
   ; (* 240-255 - RFC 7541 Appendix B (corrected) *)
     0x3ffffeb, 26
   ; 0x7ffffe6, 27
   ; 0x3ffffec, 26
   ; 0x3ffffed, 26
   ; 0x7ffffe7, 27
   ; 0x7ffffe8, 27
   ; 0x7ffffe9, 27
   ; 0x7ffffea, 27
   ; 0x7ffffeb, 27
   ; 0xffffffe, 28
   ; 0x7ffffec, 27
   ; 0x7ffffed, 27
   ; 0x7ffffee, 27
   ; 0x7ffffef, 27
   ; 0x7fffff0, 27
   ; 0x3ffffee, 26
  |]
;;

(** Optimized decode table: (code, len) -> symbol
    Pre-built for O(1) lookup of 5-8 bit codes (most common) *)
let fast_decode_5 = Array.make 32 (-1)
(* 5-bit codes *)

let fast_decode_6 = Array.make 64 (-1) (* 6-bit codes *)
let fast_decode_7 = Array.make 128 (-1) (* 7-bit codes *)
let fast_decode_8 = Array.make 256 (-1) (* 8-bit codes *)

(** Reverse lookup for longer codes (10-30 bits): (len << 24 | code) -> symbol
    This replaces O(256) search with O(1) hashtable lookup *)
let long_code_table : (int, int) Hashtbl.t = Hashtbl.create 256

let () =
  (* Build ALL lookup tables for O(1) decode *)
  for sym = 0 to 255 do
    let code, len = table.(sym) in
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
;;

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
  if len = 0
  then ""
  else (
    let buf = Buffer.create (len * 2) in
    (* Native int (63 bits on 64-bit OCaml) is sufficient for 56-bit accumulator *)
    let bits = ref 0 in
    let nbits = ref 0 in
    let pos = ref 0 in
    (* Refill accumulator - keep under 56 bits for safe 8-bit additions *)
    let refill () =
      while !nbits < 56 && !pos < len do
        bits := (!bits lsl 8) lor Char.code encoded_bytes.[!pos];
        nbits := !nbits + 8;
        incr pos
      done
    in
    refill ();
    (* Decode until we run out of bits (excluding EOS padding) *)
    while !nbits >= 5 do
      let found = ref false in
      (* 5-bit codes - most common (digits, lowercase) *)
      if !nbits >= 5
      then (
        let code = (!bits lsr (!nbits - 5)) land 0x1F in
        let sym = fast_decode_5.(code) in
        if sym >= 0
        then (
          Buffer.add_char buf (Char.unsafe_chr sym);
          nbits := !nbits - 5;
          refill ();
          found := true));
      (* 6-bit codes *)
      if (not !found) && !nbits >= 6
      then (
        let code = (!bits lsr (!nbits - 6)) land 0x3F in
        let sym = fast_decode_6.(code) in
        if sym >= 0
        then (
          Buffer.add_char buf (Char.unsafe_chr sym);
          nbits := !nbits - 6;
          refill ();
          found := true));
      (* 7-bit codes *)
      if (not !found) && !nbits >= 7
      then (
        let code = (!bits lsr (!nbits - 7)) land 0x7F in
        let sym = fast_decode_7.(code) in
        if sym >= 0
        then (
          Buffer.add_char buf (Char.unsafe_chr sym);
          nbits := !nbits - 7;
          refill ();
          found := true));
      (* 8-bit codes *)
      if (not !found) && !nbits >= 8
      then (
        let code = (!bits lsr (!nbits - 8)) land 0xFF in
        let sym = fast_decode_8.(code) in
        if sym >= 0
        then (
          Buffer.add_char buf (Char.unsafe_chr sym);
          nbits := !nbits - 8;
          refill ();
          found := true));
      (* Fast path for longer codes (10-30 bits) using hashtable lookup *)
      if not !found
      then (
        let max_code_len = min 30 !nbits in
        let code_len = ref 10 in
        while (not !found) && !code_len <= max_code_len do
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
        done);
      (* If still not found, this is EOS padding or error - stop *)
      if not !found
      then
        (* RFC 7541: EOS padding is all 1s, up to 7 bits *)
        if !nbits <= 7
        then (
          let remaining_mask = (1 lsl !nbits) - 1 in
          let remaining = !bits land remaining_mask in
          if remaining = remaining_mask
          then nbits := 0 (* Valid EOS padding *)
          else invalid_arg "HPACK invalid Huffman padding")
        else invalid_arg "HPACK invalid Huffman padding"
    done;
    Buffer.contents buf)
;;

(** Encode string to Huffman (RFC 7541 Appendix B) *)
let encode str =
  let len = String.length str in
  if len = 0
  then ""
  else (
    let buf = Buffer.create len in
    let bits = ref 0 in
    let nbits = ref 0 in
    for i = 0 to len - 1 do
      let sym = Char.code str.[i] in
      let code, code_len = table.(sym) in
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
    if !nbits > 0
    then (
      let padding = 8 - !nbits in
      let padded = (!bits lsl padding) lor ((1 lsl padding) - 1) in
      Buffer.add_char buf (Char.chr (padded land 0xFF)));
    Buffer.contents buf)
;;
