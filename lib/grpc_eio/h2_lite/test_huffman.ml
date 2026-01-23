(** Test Huffman encoding/decoding (RFC 7541 Appendix B)

    The Huffman coding in HPACK is designed to compress HTTP header values.
    Common characters (lowercase letters, digits) use fewer bits.
*)

open H2_lite

(** Test encode then decode roundtrip *)
let test_roundtrip str =
  let encoded = Hpack.Huffman.encode str in
  let decoded = Hpack.Huffman.decode encoded in
  if decoded <> str
  then (
    Printf.printf "FAIL: roundtrip for %S\n" str;
    Printf.printf "  encoded: %d bytes\n" (String.length encoded);
    Printf.printf "  decoded: %S\n" decoded;
    false)
  else true
;;

(** Test common gRPC header values *)
let test_grpc_headers () =
  let headers =
    [ "/echo.EchoService/Echo"
    ; "application/grpc"
    ; "trailers"
    ; "identity"
    ; "localhost:50051"
    ; "POST"
    ; "http"
    ; "200"
    ; "0"
    ]
  in
  let all_pass = ref true in
  List.iter (fun h -> if not (test_roundtrip h) then all_pass := false) headers;
  if !all_pass
  then Printf.printf "✓ gRPC headers: roundtrip OK\n"
  else Printf.printf "✗ gRPC headers: some failed\n";
  !all_pass
;;

(** Test ASCII printable characters *)
let test_ascii () =
  let all_pass = ref true in
  for c = 32 to 126 do
    let s = String.make 1 (Char.chr c) in
    if not (test_roundtrip s) then all_pass := false
  done;
  if !all_pass
  then Printf.printf "✓ ASCII (32-126): roundtrip OK\n"
  else Printf.printf "✗ ASCII: some failed\n";
  !all_pass
;;

(** Test compression ratio *)
let test_compression () =
  let test_cases =
    [ "www.example.com", "typical URL"
    ; "no-cache", "cache-control"
    ; "text/html; charset=utf-8", "content-type"
    ; "/service/method", "gRPC path"
    ]
  in
  Printf.printf "\nCompression ratios:\n";
  List.iter
    (fun (s, desc) ->
       let encoded = Hpack.Huffman.encode s in
       let ratio =
         float_of_int (String.length encoded) /. float_of_int (String.length s) *. 100.0
       in
       Printf.printf
         "  %s: %d -> %d bytes (%.1f%%)\n"
         desc
         (String.length s)
         (String.length encoded)
         ratio)
    test_cases;
  Printf.printf "✓ Compression ratio test complete\n";
  true
;;

(** Test the Huffman table is correct (spot check) *)
let test_table_sanity () =
  (* RFC 7541 Appendix B reference values *)
  let expected =
    [ (* Common ASCII *)
      0x30, (0x0, 5)
    ; (* '0' = 0x30 = 48 *)
      0x61, (0x3, 5)
    ; (* 'a' = 0x61 = 97 *)
      0x65, (0x5, 5)
    ; (* 'e' = 0x65 = 101 *)
      0x20, (0x14, 6)
    ; (* space = 0x20 = 32 *)
      (* High bytes that were broken *)
      0xC0, (0x3ffffe0, 26)
    ; (* 192 *)
      0xD0, (0x7fff2, 19)
    ; (* 208 *)
      0xE0, (0xfffec, 20)
    ; (* 224 *)
      0xF0, (0x3ffffeb, 26)
    ; (* 240 *)
      0xFF, (0x3ffffee, 26) (* 255 *)
    ]
  in
  let all_pass = ref true in
  List.iter
    (fun (sym, (expected_code, expected_len)) ->
       let actual_code, actual_len = Hpack.Huffman.table.(sym) in
       if actual_code <> expected_code || actual_len <> expected_len
       then (
         Printf.printf
           "FAIL: table[%d] = (0x%x, %d), expected (0x%x, %d)\n"
           sym
           actual_code
           actual_len
           expected_code
           expected_len;
         all_pass := false))
    expected;
  if !all_pass
  then Printf.printf "✓ Huffman table: spot check OK\n"
  else Printf.printf "✗ Huffman table: errors found\n";
  !all_pass
;;

(** Test decode_string with Huffman flag *)
let test_decode_string () =
  (* Create a buffer with Huffman-encoded "www" *)
  let www_huffman = Hpack.Huffman.encode "www" in
  let buf = Cstruct.create (1 + String.length www_huffman) in
  (* Set Huffman bit (0x80) and length *)
  Cstruct.set_uint8 buf 0 (0x80 lor String.length www_huffman);
  Cstruct.blit_from_string www_huffman 0 buf 1 (String.length www_huffman);
  let decoded, _ = Hpack.decode_string buf ~offset:0 in
  if decoded = "www"
  then (
    Printf.printf "✓ decode_string with Huffman: OK\n";
    true)
  else (
    Printf.printf "✗ decode_string: expected \"www\", got %S\n" decoded;
    false)
;;

(** Test encode_string chooses Huffman only when smaller *)
let test_encode_string () =
  let sample = "www.example.com" in
  let huffman = Hpack.Huffman.encode sample in
  let expect_huffman = String.length huffman < String.length sample in
  let buf = Cstruct.create 256 in
  let _off = Hpack.encode_string buf ~offset:0 sample in
  let first = Cstruct.get_uint8 buf 0 in
  let used_huffman = first land 0x80 <> 0 in
  let decoded, _ = Hpack.decode_string buf ~offset:0 in
  if decoded <> sample
  then (
    Printf.printf "✗ encode_string roundtrip failed: %S -> %S\n" sample decoded;
    false)
  else if used_huffman <> expect_huffman
  then (
    Printf.printf
      "✗ encode_string Huffman flag mismatch (expected %b, got %b)\n"
      expect_huffman
      used_huffman;
    false)
  else (
    Printf.printf "✓ encode_string Huffman selection: OK\n";
    true)
;;

let () =
  Printf.printf "\n╔═══════════════════════════════════════════════════════╗\n";
  Printf.printf "║     Huffman Encoder/Decoder Tests (RFC 7541 App B)    ║\n";
  Printf.printf "╚═══════════════════════════════════════════════════════╝\n\n";
  let results =
    [ test_table_sanity ()
    ; test_grpc_headers ()
    ; test_ascii ()
    ; test_compression ()
    ; test_decode_string ()
    ; test_encode_string ()
    ]
  in
  let passed = List.filter (fun x -> x) results |> List.length in
  let total = List.length results in
  Printf.printf "\n";
  if passed = total
  then Printf.printf "✅ All %d Huffman tests passed!\n" total
  else Printf.printf "❌ %d/%d tests failed\n" (total - passed) total
;;
