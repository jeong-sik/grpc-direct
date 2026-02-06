(** Tests for H2_lite.Hpack — HPACK header compression (RFC 7541) *)

open H2_lite

(* ── Static table ─────────────────────────────────────────────── *)

let test_static_table_size () =
  assert (Hpack.static_table_size = 61);
  assert (Array.length Hpack.static_table = 61);
  Printf.printf "PASS static_table_size = 61\n%!"
;;

let test_static_table_known_entries () =
  (* RFC 7541 Appendix A: index 1 = :authority, "" *)
  assert (Hpack.static_table.(0) = (":authority", ""));
  (* index 2 = :method GET *)
  assert (Hpack.static_table.(1) = (":method", "GET"));
  (* index 3 = :method POST *)
  assert (Hpack.static_table.(2) = (":method", "POST"));
  (* index 4 = :path / *)
  assert (Hpack.static_table.(3) = (":path", "/"));
  (* index 8 = :status 200 *)
  assert (Hpack.static_table.(7) = (":status", "200"));
  (* index 61 = www-authenticate "" *)
  assert (fst Hpack.static_table.(60) = "www-authenticate");
  Printf.printf "PASS static_table known entries\n%!"
;;

(* ── create / entry_size ──────────────────────────────────────── *)

let test_create () =
  let ctx = Hpack.create () in
  assert (ctx.max_size = 4096);
  assert (ctx.table_size = 0);
  assert (ctx.table_len = 0);
  assert (ctx.dynamic_table = []);
  let ctx2 = Hpack.create ~max_size:1024 () in
  assert (ctx2.max_size = 1024);
  Printf.printf "PASS create\n%!"
;;

let test_entry_size () =
  (* RFC 7541 Section 4.1: size = len(name) + len(value) + 32 *)
  assert (Hpack.entry_size "name" "value" = 4 + 5 + 32);
  assert (Hpack.entry_size "" "" = 32);
  assert (Hpack.entry_size "content-type" "application/grpc" = 12 + 16 + 32);
  Printf.printf "PASS entry_size\n%!"
;;

let test_header_list_size () =
  let headers = [("name", "value"); ("foo", "bar")] in
  let expected = (4 + 5 + 32) + (3 + 3 + 32) in
  assert (Hpack.header_list_size headers = expected);
  assert (Hpack.header_list_size [] = 0);
  Printf.printf "PASS header_list_size\n%!"
;;

(* ── Dynamic table operations ─────────────────────────────────── *)

let test_add_entry () =
  let ctx = Hpack.create ~max_size:4096 () in
  Hpack.add_entry ctx "custom-header" "custom-value";
  assert (ctx.table_len = 1);
  assert (ctx.table_size = Hpack.entry_size "custom-header" "custom-value");
  Printf.printf "PASS add_entry\n%!"
;;

let test_add_entry_eviction () =
  (* Max size = 64, so only one small entry fits *)
  let ctx = Hpack.create ~max_size:64 () in
  (* entry size = 3 + 3 + 32 = 38 bytes *)
  Hpack.add_entry ctx "foo" "bar";
  assert (ctx.table_len = 1);
  assert (ctx.table_size = 38);
  (* Add another: 3 + 3 + 32 = 38, total would be 76 > 64 *)
  Hpack.add_entry ctx "baz" "qux";
  (* Oldest ("foo","bar") should be evicted *)
  assert (ctx.table_len = 1);
  assert (ctx.table_size = 38);
  Printf.printf "PASS add_entry eviction\n%!"
;;

let test_set_max_size () =
  let ctx = Hpack.create ~max_size:4096 () in
  Hpack.add_entry ctx "header1" "value1";
  Hpack.add_entry ctx "header2" "value2";
  assert (ctx.table_len = 2);
  (* Reduce max_size to 0 -- should evict everything *)
  Hpack.set_max_size ctx 0;
  assert (ctx.table_len = 0);
  assert (ctx.table_size = 0);
  assert (ctx.max_size = 0);
  Printf.printf "PASS set_max_size eviction\n%!"
;;

let test_set_max_size_negative () =
  let ctx = Hpack.create () in
  (try
    Hpack.set_max_size ctx (-1);
    assert false
  with Invalid_argument _ -> ());
  Printf.printf "PASS set_max_size rejects negative\n%!"
;;

(* ── Lookup ───────────────────────────────────────────────────── *)

let test_lookup_static_name () =
  (* ":method" is in static table *)
  (match Hpack.lookup_static_name ":method" with
  | Some idx -> assert (idx >= 1 && idx <= 3)
  | None -> assert false);
  (* "content-type" is at index 31 *)
  (match Hpack.lookup_static_name "content-type" with
  | Some idx -> assert (idx = 31)
  | None -> assert false);
  (* Unknown name *)
  assert (Hpack.lookup_static_name "x-custom" = None);
  Printf.printf "PASS lookup_static_name\n%!"
;;

let test_lookup_static () =
  (* :method POST = index 3 *)
  (match Hpack.lookup_static ":method" "POST" with
  | Some idx -> assert (idx = 3)
  | None -> assert false);
  (* :status 200 = index 8 *)
  (match Hpack.lookup_static ":status" "200" with
  | Some idx -> assert (idx = 8)
  | None -> assert false);
  (* Empty value never matches *)
  assert (Hpack.lookup_static ":authority" "" = None);
  (* Non-existent pair *)
  assert (Hpack.lookup_static ":method" "DELETE" = None);
  Printf.printf "PASS lookup_static\n%!"
;;

let test_lookup_dynamic () =
  let ctx = Hpack.create () in
  Hpack.add_entry ctx "x-custom" "value1";
  (* Dynamic table entry at index 62 (61 static + 1) *)
  (match Hpack.lookup_dynamic ctx "x-custom" "value1" with
  | Some idx -> assert (idx = 62)
  | None -> assert false);
  (* Non-matching value *)
  assert (Hpack.lookup_dynamic ctx "x-custom" "value2" = None);
  Printf.printf "PASS lookup_dynamic\n%!"
;;

let test_lookup () =
  let ctx = Hpack.create () in
  (* Static match *)
  (match Hpack.lookup ctx ":method" "POST" with
  | Some idx -> assert (idx = 3)
  | None -> assert false);
  (* Dynamic match *)
  Hpack.add_entry ctx "x-custom" "val";
  (match Hpack.lookup ctx "x-custom" "val" with
  | Some idx -> assert (idx = 62)
  | None -> assert false);
  Printf.printf "PASS lookup\n%!"
;;

(* ── Integer encoding/decoding (RFC 7541 Section 5.1) ─────────── *)

let test_encode_decode_integer_small () =
  let buf = Cstruct.create 16 in
  (* Value fits in prefix *)
  let off = Hpack.encode_integer buf ~offset:0 ~prefix_bits:5 ~value:10 in
  assert (off = 1);
  let v, off' = Hpack.decode_integer buf ~offset:0 ~prefix_bits:5 in
  assert (v = 10);
  assert (off' = 1);
  Printf.printf "PASS encode/decode integer small\n%!"
;;

let test_encode_decode_integer_large () =
  let buf = Cstruct.create 16 in
  (* Value needs multi-byte: 1337 with 5-bit prefix *)
  let off = Hpack.encode_integer buf ~offset:0 ~prefix_bits:5 ~value:1337 in
  assert (off > 1);
  let v, off' = Hpack.decode_integer buf ~offset:0 ~prefix_bits:5 in
  assert (v = 1337);
  assert (off' = off);
  Printf.printf "PASS encode/decode integer large (1337)\n%!"
;;

let test_encode_decode_integer_boundary () =
  (* Test boundary: value = 2^N - 1 exactly (where N = prefix_bits) *)
  let buf = Cstruct.create 16 in
  let prefix_bits = 5 in
  let boundary = (1 lsl prefix_bits) - 1 in
  let off = Hpack.encode_integer buf ~offset:0 ~prefix_bits ~value:boundary in
  let v, off' = Hpack.decode_integer buf ~offset:0 ~prefix_bits in
  assert (v = boundary);
  assert (off' = off);
  Printf.printf "PASS encode/decode integer boundary (31)\n%!"
;;

let test_encode_decode_integer_with_prefix () =
  let buf = Cstruct.create 16 in
  (* Indexed header (0x80 prefix, 7-bit prefix) *)
  let off = Hpack.encode_integer_with_prefix buf
    ~offset:0 ~prefix_byte:0x80 ~prefix_bits:7 ~value:3 in
  assert (off = 1);
  let byte0 = Cstruct.get_uint8 buf 0 in
  assert (byte0 = 0x83);  (* 0x80 | 3 *)
  let v, _ = Hpack.decode_integer buf ~offset:0 ~prefix_bits:7 in
  assert (v = 3);
  Printf.printf "PASS encode_integer_with_prefix\n%!"
;;

let test_encode_decode_integer_various_prefix_bits () =
  let values = [0; 1; 30; 31; 127; 128; 255; 1000; 65535] in
  let prefix_bits_list = [4; 5; 6; 7] in
  List.iter (fun prefix_bits ->
    List.iter (fun value ->
      let buf = Cstruct.create 16 in
      let off = Hpack.encode_integer buf ~offset:0 ~prefix_bits ~value in
      let v, off' = Hpack.decode_integer buf ~offset:0 ~prefix_bits in
      assert (v = value);
      assert (off' = off))
      values)
    prefix_bits_list;
  Printf.printf "PASS encode/decode integer various prefix bits\n%!"
;;

(* ── Huffman encoding/decoding ────────────────────────────────── *)

let test_huffman_empty () =
  let encoded = Hpack.Huffman.encode "" in
  assert (encoded = "");
  let decoded = Hpack.Huffman.decode "" in
  assert (decoded = "");
  Printf.printf "PASS Huffman empty string\n%!"
;;

let test_huffman_roundtrip_ascii () =
  for c = 32 to 126 do
    let s = String.make 1 (Char.chr c) in
    let encoded = Hpack.Huffman.encode s in
    let decoded = Hpack.Huffman.decode encoded in
    assert (decoded = s)
  done;
  Printf.printf "PASS Huffman roundtrip all printable ASCII\n%!"
;;

let test_huffman_roundtrip_grpc_headers () =
  let headers = [
    "POST"; "http"; "https"; "/echo.EchoService/Echo";
    "application/grpc"; "trailers"; "identity"; "gzip";
    "localhost:50051"; "200"; "0"; "grpc-status";
    "content-type"; "te"; "user-agent"; "grpc-go/1.50.0"
  ] in
  List.iter (fun h ->
    let encoded = Hpack.Huffman.encode h in
    let decoded = Hpack.Huffman.decode encoded in
    assert (decoded = h))
    headers;
  Printf.printf "PASS Huffman roundtrip gRPC headers\n%!"
;;

let test_huffman_compression () =
  (* Lowercase ASCII should compress well (5-6 bit codes) *)
  let s = "www.example.com" in
  let encoded = Hpack.Huffman.encode s in
  assert (String.length encoded < String.length s);
  Printf.printf "PASS Huffman compression (www.example.com: %d -> %d bytes)\n%!"
    (String.length s) (String.length encoded)
;;

let test_huffman_table_sanity () =
  (* Verify table has 256 entries *)
  assert (Array.length Hpack.Huffman.table = 256);
  (* All code lengths should be 5-30 bits *)
  Array.iter (fun (_code, len) ->
    assert (len >= 5 && len <= 30))
    Hpack.Huffman.table;
  Printf.printf "PASS Huffman table sanity\n%!"
;;

(* ── String encoding/decoding (RFC 7541 Section 5.2) ──────────── *)

let test_encode_decode_string_literal () =
  let buf = Cstruct.create 256 in
  let s = "hello" in
  let off = Hpack.encode_string buf ~offset:0 s in
  let decoded, off' = Hpack.decode_string buf ~offset:0 in
  assert (decoded = s);
  assert (off' = off);
  Printf.printf "PASS encode/decode string literal\n%!"
;;

let test_encode_decode_string_huffman () =
  let buf = Cstruct.create 256 in
  let s = "www.example.com" in
  let off = Hpack.encode_string buf ~offset:0 s in
  (* Check if Huffman bit is set *)
  let first = Cstruct.get_uint8 buf 0 in
  let huffman_used = first land 0x80 <> 0 in
  let decoded, off' = Hpack.decode_string buf ~offset:0 in
  assert (decoded = s);
  assert (off' = off);
  (* Huffman should be used because it compresses well *)
  assert huffman_used;
  Printf.printf "PASS encode/decode string with Huffman\n%!"
;;

let test_encode_decode_string_empty () =
  let buf = Cstruct.create 16 in
  let off = Hpack.encode_string buf ~offset:0 "" in
  let decoded, off' = Hpack.decode_string buf ~offset:0 in
  assert (decoded = "");
  assert (off' = off);
  Printf.printf "PASS encode/decode empty string\n%!"
;;

(* ── Full HPACK encode/decode roundtrip ───────────────────────── *)

let test_encode_decode_indexed () =
  let enc = Hpack.create () in
  let dec = Hpack.create () in
  (* :method POST is in static table at index 3 *)
  let headers = [(":method", "POST")] in
  let block = Hpack.encode enc headers in
  let decoded = Hpack.decode dec block in
  assert (decoded = [(":method", "POST")]);
  Printf.printf "PASS encode/decode indexed header\n%!"
;;

let test_encode_decode_literal_indexed_name () =
  let enc = Hpack.create () in
  let dec = Hpack.create () in
  (* :authority has static index, but value is literal *)
  let headers = [(":authority", "localhost:8080")] in
  let block = Hpack.encode enc headers in
  let decoded = Hpack.decode dec block in
  assert (decoded = [(":authority", "localhost:8080")]);
  Printf.printf "PASS encode/decode literal with indexed name\n%!"
;;

let test_encode_decode_literal_new_name () =
  let enc = Hpack.create () in
  let dec = Hpack.create () in
  let headers = [("x-custom-header", "custom-value")] in
  let block = Hpack.encode enc headers in
  let decoded = Hpack.decode dec block in
  assert (decoded = [("x-custom-header", "custom-value")]);
  Printf.printf "PASS encode/decode literal with new name\n%!"
;;

let test_encode_decode_multiple_headers () =
  let enc = Hpack.create () in
  let dec = Hpack.create () in
  let headers = [
    (":method", "POST");
    (":scheme", "http");
    (":path", "/echo.EchoService/Echo");
    (":authority", "localhost:50051");
    ("content-type", "application/grpc");
    ("te", "trailers");
  ] in
  let block = Hpack.encode enc headers in
  let decoded = Hpack.decode dec block in
  assert (List.length decoded = List.length headers);
  List.iter2 (fun (n1, v1) (n2, v2) ->
    assert (n1 = n2);
    assert (v1 = v2))
    headers decoded;
  Printf.printf "PASS encode/decode multiple gRPC headers\n%!"
;;

let test_encode_decode_dynamic_table_reuse () =
  (* Encode same headers twice -- second time should use indexed *)
  let enc = Hpack.create () in
  let dec = Hpack.create () in
  let headers = [("x-request-id", "abc123")] in
  let block1 = Hpack.encode enc headers in
  let decoded1 = Hpack.decode dec block1 in
  assert (decoded1 = headers);
  (* Second encoding should be more compact (indexed) *)
  let block2 = Hpack.encode enc headers in
  let decoded2 = Hpack.decode dec block2 in
  assert (decoded2 = headers);
  assert (Cstruct.length block2 <= Cstruct.length block1);
  Printf.printf "PASS encode/decode dynamic table reuse\n%!"
;;

let test_dynamic_table_eviction_during_decode () =
  (* Use a small max_size to force eviction *)
  let enc = Hpack.create ~max_size:80 () in
  let dec = Hpack.create ~max_size:80 () in
  (* Entry 1: 3 + 3 + 32 = 38 bytes *)
  let h1 = [("aaa", "bbb")] in
  let b1 = Hpack.encode enc h1 in
  let d1 = Hpack.decode dec b1 in
  assert (d1 = h1);
  assert (enc.table_len = 1);
  assert (dec.table_len = 1);
  (* Entry 2: 3 + 3 + 32 = 38 bytes -> total would be 76, fits in 80 *)
  let h2 = [("ccc", "ddd")] in
  let b2 = Hpack.encode enc h2 in
  let d2 = Hpack.decode dec b2 in
  assert (d2 = h2);
  assert (enc.table_len = 2);
  assert (dec.table_len = 2);
  (* Entry 3: 3 + 3 + 32 = 38 bytes -> total would be 114 > 80, must evict *)
  let h3 = [("eee", "fff")] in
  let b3 = Hpack.encode enc h3 in
  let d3 = Hpack.decode dec b3 in
  assert (d3 = h3);
  (* Should have evicted the oldest entry *)
  assert (enc.table_len = 2);
  assert (dec.table_len = 2);
  Printf.printf "PASS dynamic table eviction\n%!"
;;

(* ── get_dynamic_entry bounds checking ────────────────────────── *)

let test_get_dynamic_entry_bounds () =
  let ctx = Hpack.create () in
  Hpack.add_entry ctx "name" "value";
  (* Valid index: 62 (61 static + 1) *)
  let entry = Hpack.get_dynamic_entry ctx 62 in
  assert (entry.name = "name");
  assert (entry.value = "value");
  (* Invalid index: too high *)
  (try
    let _ = Hpack.get_dynamic_entry ctx 63 in
    assert false
  with Invalid_argument _ -> ());
  (* Invalid index: static range *)
  (try
    let _ = Hpack.get_dynamic_entry ctx 1 in
    assert false
  with Invalid_argument _ -> ());
  Printf.printf "PASS get_dynamic_entry bounds\n%!"
;;

(* ── decode rejects index 0 ──────────────────────────────────── *)

let test_decode_rejects_index_zero () =
  let ctx = Hpack.create () in
  (* Create a buffer with indexed representation, index=0 *)
  let buf = Cstruct.create 1 in
  Cstruct.set_uint8 buf 0 0x80;  (* 0x80 | 0 = indexed, index 0 *)
  (try
    let _ = Hpack.decode ctx buf in
    assert false
  with Invalid_argument _ -> ());
  Printf.printf "PASS decode rejects index 0\n%!"
;;

(* ── gRPC helpers ─────────────────────────────────────────────── *)

let test_grpc_request_headers () =
  let headers = Hpack.grpc_request_headers
    ~authority:"localhost:50051" ~path:"/echo/Echo" in
  assert (List.length headers = 6);
  assert (List.assoc ":method" headers = "POST");
  assert (List.assoc ":scheme" headers = "http");
  assert (List.assoc ":path" headers = "/echo/Echo");
  assert (List.assoc ":authority" headers = "localhost:50051");
  assert (List.assoc "content-type" headers = "application/grpc");
  assert (List.assoc "te" headers = "trailers");
  Printf.printf "PASS grpc_request_headers\n%!"
;;

let test_grpc_response_headers () =
  let headers = Hpack.grpc_response_headers () in
  assert (List.assoc ":status" headers = "200");
  assert (List.assoc "content-type" headers = "application/grpc");
  Printf.printf "PASS grpc_response_headers\n%!"
;;

let test_grpc_trailers () =
  let t0 = Hpack.grpc_trailers 0 in
  assert (List.assoc "grpc-status" t0 = "0");
  let t1 = Hpack.grpc_trailers 1 in
  assert (List.assoc "grpc-status" t1 = "1");
  let t2 = Hpack.grpc_trailers 2 in
  assert (List.assoc "grpc-status" t2 = "2");
  let t_msg = Hpack.grpc_trailers ~message:"not found" 5 in
  assert (List.assoc "grpc-status" t_msg = "5");
  assert (List.assoc "grpc-message" t_msg = "not found");
  Printf.printf "PASS grpc_trailers\n%!"
;;

(* ── Pre-encoded fast paths ───────────────────────────────────── *)

let test_encode_response_headers_fast () =
  let block = Hpack.encode_response_headers_fast () in
  assert (Cstruct.length block > 0);
  Printf.printf "PASS encode_response_headers_fast\n%!"
;;

let test_encode_trailers_fast () =
  let block0 = Hpack.encode_trailers_fast 0 in
  assert (Cstruct.length block0 > 0);
  let block1 = Hpack.encode_trailers_fast 1 in
  assert (Cstruct.length block1 > 0);
  Printf.printf "PASS encode_trailers_fast\n%!"
;;

(* ── remove_last ──────────────────────────────────────────────── *)

let test_remove_last () =
  let (removed, rest) = Hpack.remove_last [1; 2; 3] in
  assert (removed = Some 3);
  assert (rest = [1; 2]);
  let (removed2, rest2) = Hpack.remove_last [42] in
  assert (removed2 = Some 42);
  assert (rest2 = []);
  let (removed3, rest3) = Hpack.remove_last [] in
  assert (removed3 = None);
  assert (rest3 = []);
  Printf.printf "PASS remove_last\n%!"
;;

(* ── Multi-request scenario ───────────────────────────────────── *)

let test_multi_request_scenario () =
  let enc = Hpack.create () in
  let dec = Hpack.create () in
  (* Request 1 *)
  let req1 = Hpack.grpc_request_headers ~authority:"localhost:50051" ~path:"/svc/Method1" in
  let block1 = Hpack.encode enc req1 in
  let decoded1 = Hpack.decode dec block1 in
  assert (List.length decoded1 = List.length req1);
  (* Request 2 -- similar headers, dynamic table should help *)
  let req2 = Hpack.grpc_request_headers ~authority:"localhost:50051" ~path:"/svc/Method2" in
  let block2 = Hpack.encode enc req2 in
  let decoded2 = Hpack.decode dec block2 in
  assert (List.length decoded2 = List.length req2);
  assert (List.assoc ":path" decoded2 = "/svc/Method2");
  (* block2 should be same size or smaller due to dynamic table *)
  Printf.printf "PASS multi-request scenario (block1=%d, block2=%d bytes)\n%!"
    (Cstruct.length block1) (Cstruct.length block2)
;;

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Printf.printf "\n=== HPACK Tests (RFC 7541) ===\n\n%!";
  test_static_table_size ();
  test_static_table_known_entries ();
  test_create ();
  test_entry_size ();
  test_header_list_size ();
  test_add_entry ();
  test_add_entry_eviction ();
  test_set_max_size ();
  test_set_max_size_negative ();
  test_lookup_static_name ();
  test_lookup_static ();
  test_lookup_dynamic ();
  test_lookup ();
  test_encode_decode_integer_small ();
  test_encode_decode_integer_large ();
  test_encode_decode_integer_boundary ();
  test_encode_decode_integer_with_prefix ();
  test_encode_decode_integer_various_prefix_bits ();
  test_huffman_empty ();
  test_huffman_roundtrip_ascii ();
  test_huffman_roundtrip_grpc_headers ();
  test_huffman_compression ();
  test_huffman_table_sanity ();
  test_encode_decode_string_literal ();
  test_encode_decode_string_huffman ();
  test_encode_decode_string_empty ();
  test_encode_decode_indexed ();
  test_encode_decode_literal_indexed_name ();
  test_encode_decode_literal_new_name ();
  test_encode_decode_multiple_headers ();
  test_encode_decode_dynamic_table_reuse ();
  test_dynamic_table_eviction_during_decode ();
  test_get_dynamic_entry_bounds ();
  test_decode_rejects_index_zero ();
  test_grpc_request_headers ();
  test_grpc_response_headers ();
  test_grpc_trailers ();
  test_encode_response_headers_fast ();
  test_encode_trailers_fast ();
  test_remove_last ();
  test_multi_request_scenario ();
  Printf.printf "\n=== All HPACK tests passed. ===\n%!"
;;
