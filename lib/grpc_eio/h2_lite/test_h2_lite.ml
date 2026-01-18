(** Unit tests for H2_lite module *)

open H2_lite

let test_buffer_pool_acquire_release () =
  (* Test basic acquire/release cycle *)
  let buf1 = Buffer_pool.acquire ~size:100 in
  assert (Bytes.length buf1 >= 100);
  (* Should get 256-byte buffer (smallest power-of-2 >= 100) *)
  assert (Bytes.length buf1 = 256);
  Buffer_pool.release buf1;

  (* Acquire again - should reuse from pool *)
  let buf2 = Buffer_pool.acquire ~size:100 in
  assert (Bytes.length buf2 = 256);
  Buffer_pool.release buf2;

  Printf.printf "✓ buffer_pool acquire/release\n"

let test_buffer_pool_size_classes () =
  (* Test all size classes *)
  let expected = [256; 512; 1024; 2048; 4096; 8192; 16384; 32768] in
  List.iter (fun size ->
    let buf = Buffer_pool.acquire ~size in
    assert (Bytes.length buf = size);
    Buffer_pool.release buf
  ) expected;

  (* Test sizes that round up *)
  let buf = Buffer_pool.acquire ~size:300 in
  assert (Bytes.length buf = 512);  (* rounds up to 512 *)
  Buffer_pool.release buf;

  Printf.printf "✓ buffer_pool size classes\n"

let test_buffer_pool_stats () =
  (* Prewarm and check stats *)
  Buffer_pool.prewarm ~count_per_class:2;
  let stats = Buffer_pool.stats () in
  assert (stats.total_allocated >= 0);
  Printf.printf "✓ buffer_pool stats (hit_rate: %.2f%%)\n" (stats.hit_rate *. 100.)

let test_frame_header_parse () =
  (* Create a simple DATA frame header *)
  let buf = Cstruct.create 9 in
  (* Length: 100 (3 bytes big-endian) *)
  Cstruct.set_uint8 buf 0 0;
  Cstruct.set_uint8 buf 1 0;
  Cstruct.set_uint8 buf 2 100;
  (* Type: DATA (0x0) *)
  Cstruct.set_uint8 buf 3 0;
  (* Flags: END_STREAM (0x1) *)
  Cstruct.set_uint8 buf 4 1;
  (* Stream ID: 1 *)
  Cstruct.BE.set_uint32 buf 5 1l;

  let header, remaining = Frame.parse_header buf in
  assert (header.length = 100);
  assert (header.frame_type = Frame.Data);
  assert (Frame.Flags.is_set header.flags Frame.Flags.end_stream);
  assert (header.stream_id = 1l);
  assert (Cstruct.length remaining = 0);

  Printf.printf "✓ frame header parse\n"

let test_frame_make_data () =
  let payload = Cstruct.of_string "Hello, gRPC!" in
  let frame = Frame.make_data ~stream_id:1l ~end_stream:true payload in

  assert (frame.header.length = 12);  (* "Hello, gRPC!" = 12 bytes *)
  assert (frame.header.frame_type = Frame.Data);
  assert (Frame.Flags.is_set frame.header.flags Frame.Flags.end_stream);
  assert (frame.header.stream_id = 1l);

  Printf.printf "✓ frame make_data\n"

let test_frame_make_headers () =
  let headers = Cstruct.of_string "encoded-headers" in
  let frame = Frame.make_headers ~stream_id:3l ~end_stream:false ~end_headers:true headers in

  assert (frame.header.frame_type = Frame.Headers);
  assert (Frame.Flags.is_set frame.header.flags Frame.Flags.end_headers);
  assert (not (Frame.Flags.is_set frame.header.flags Frame.Flags.end_stream));
  assert (frame.header.stream_id = 3l);

  Printf.printf "✓ frame make_headers\n"

let test_frame_roundtrip () =
  (* Create a frame, serialize it, parse it back *)
  let original_payload = Cstruct.of_string "test payload" in
  let frame = Frame.make_data ~stream_id:5l ~end_stream:false original_payload in

  (* Serialize *)
  let serialized = Frame.to_cstruct frame in
  assert (Cstruct.length serialized = Frame.header_size + 12);

  (* Parse back *)
  match Frame.parse serialized with
  | Some (parsed, remaining) ->
    assert (Cstruct.length remaining = 0);
    assert (parsed.header.length = frame.header.length);
    assert (parsed.header.frame_type = frame.header.frame_type);
    assert (parsed.header.stream_id = frame.header.stream_id);
    assert (Cstruct.to_string parsed.payload = "test payload");
    Printf.printf "✓ frame roundtrip\n"
  | None ->
    failwith "Failed to parse serialized frame"

let test_frame_ping () =
  let opaque = Cstruct.create 8 in
  for i = 0 to 7 do Cstruct.set_uint8 opaque i (i + 1) done;

  let ping = Frame.make_ping ~ack:false opaque in
  assert (ping.header.frame_type = Frame.Ping);
  assert (ping.header.length = 8);
  assert (ping.header.stream_id = 0l);  (* PING is connection-level *)
  assert (not (Frame.Flags.is_set ping.header.flags Frame.Flags.ack));

  let pong = Frame.make_ping ~ack:true opaque in
  assert (Frame.Flags.is_set pong.header.flags Frame.Flags.ack);

  Printf.printf "✓ frame ping/pong\n"

let test_grpc_message_encode_decode () =
  let body = Cstruct.of_string "protobuf message" in
  let encoded = H2_lite.Grpc_message.encode body in

  (* Check header: 1 byte compression + 4 bytes length *)
  assert (Cstruct.length encoded = 5 + 16);
  assert (Cstruct.get_uint8 encoded 0 = 0);  (* not compressed *)

  let decoded, remaining = H2_lite.Grpc_message.decode encoded in
  assert (Cstruct.length remaining = 0);
  assert (Cstruct.to_string decoded = "protobuf message");

  Printf.printf "✓ gRPC message encode/decode\n"

let test_hpack_lite_encode_int () =
  let buf = Cstruct.create 10 in

  (* Small value that fits in prefix *)
  let pos = H2_lite.Hpack_lite.encode_int ~prefix_bits:5 10 buf 0 in
  assert (pos = 1);
  assert (Cstruct.get_uint8 buf 0 = 10);

  (* Value that doesn't fit in prefix (needs continuation) *)
  let pos = H2_lite.Hpack_lite.encode_int ~prefix_bits:5 1337 buf 0 in
  assert (pos > 1);  (* multi-byte encoding *)

  Printf.printf "✓ hpack_lite encode_int\n"

let () =
  Printf.printf "\n=== H2_lite Unit Tests ===\n\n";

  (* Buffer Pool tests *)
  test_buffer_pool_acquire_release ();
  test_buffer_pool_size_classes ();
  test_buffer_pool_stats ();

  (* Frame tests *)
  test_frame_header_parse ();
  test_frame_make_data ();
  test_frame_make_headers ();
  test_frame_roundtrip ();
  test_frame_ping ();

  (* gRPC message tests *)
  test_grpc_message_encode_decode ();

  (* HPACK tests *)
  test_hpack_lite_encode_int ();

  Printf.printf "\n=== All tests passed! ===\n"
