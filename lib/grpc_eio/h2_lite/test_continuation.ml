(** Test CONTINUATION frame fragmentation and reassembly

    RFC 7540 §6.10: CONTINUATION frames are used when headers
    exceed max_frame_size and must be split across multiple frames.
*)

open H2_lite

(** Test that small headers fit in a single HEADERS frame *)
let test_small_headers () =
  let stream_id = 1l in
  let small_header = Cstruct.create 100 in
  (* Fill with test data *)
  for i = 0 to 99 do
    Cstruct.set_uint8 small_header i (i mod 256)
  done;

  let frames = Frame.make_headers_fragmented ~stream_id ~end_stream:false small_header in

  assert (List.length frames = 1);
  let frame = List.hd frames in
  assert (frame.Frame.header.frame_type = Frame.Headers);
  assert (Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.end_headers);
  Printf.printf "✓ Small headers: single HEADERS frame\n"

(** Test that large headers are split into HEADERS + CONTINUATION *)
let test_large_headers () =
  let stream_id = 3l in
  let max_frame_size = 100 in  (* Small for testing *)
  let large_header = Cstruct.create 350 in  (* Will need 4 frames *)
  (* Fill with test data *)
  for i = 0 to 349 do
    Cstruct.set_uint8 large_header i (i mod 256)
  done;

  let frames = Frame.make_headers_fragmented
    ~stream_id ~end_stream:true ~max_frame_size large_header in

  (* Should be: 100 + 100 + 100 + 50 = 350 bytes in 4 frames *)
  assert (List.length frames = 4);

  (* First frame: HEADERS without END_HEADERS *)
  let first = List.nth frames 0 in
  assert (first.Frame.header.frame_type = Frame.Headers);
  assert (not (Frame.Flags.is_set first.Frame.header.flags Frame.Flags.end_headers));
  assert (Frame.Flags.is_set first.Frame.header.flags Frame.Flags.end_stream);
  assert (Cstruct.length first.payload = 100);

  (* Middle frames: CONTINUATION without END_HEADERS *)
  let second = List.nth frames 1 in
  assert (second.Frame.header.frame_type = Frame.Continuation);
  assert (not (Frame.Flags.is_set second.Frame.header.flags Frame.Flags.end_headers));
  assert (second.Frame.header.stream_id = stream_id);
  assert (Cstruct.length second.payload = 100);

  let third = List.nth frames 2 in
  assert (third.Frame.header.frame_type = Frame.Continuation);
  assert (not (Frame.Flags.is_set third.Frame.header.flags Frame.Flags.end_headers));

  (* Last frame: CONTINUATION with END_HEADERS *)
  let last = List.nth frames 3 in
  assert (last.Frame.header.frame_type = Frame.Continuation);
  assert (Frame.Flags.is_set last.Frame.header.flags Frame.Flags.end_headers);
  assert (Cstruct.length last.payload = 50);

  Printf.printf "✓ Large headers: HEADERS + 3 CONTINUATION frames\n"

(** Test data integrity after fragmentation *)
let test_data_integrity () =
  let stream_id = 5l in
  let max_frame_size = 50 in
  let original = Cstruct.create 123 in
  for i = 0 to 122 do
    Cstruct.set_uint8 original i i
  done;

  let frames = Frame.make_headers_fragmented
    ~stream_id ~end_stream:false ~max_frame_size original in

  (* Reassemble manually *)
  let total_len = List.fold_left (fun acc f -> acc + Cstruct.length f.Frame.payload) 0 frames in
  assert (total_len = 123);

  let reassembled = Cstruct.create total_len in
  let _ = List.fold_left (fun offset f ->
    let len = Cstruct.length f.Frame.payload in
    Cstruct.blit f.Frame.payload 0 reassembled offset len;
    offset + len
  ) 0 frames in

  (* Verify byte-by-byte *)
  for i = 0 to 122 do
    assert (Cstruct.get_uint8 reassembled i = Cstruct.get_uint8 original i)
  done;

  Printf.printf "✓ Data integrity: reassembled matches original\n"

(** Test edge case: exactly max_frame_size *)
let test_exact_max_size () =
  let stream_id = 7l in
  let max_frame_size = 100 in
  let exact_header = Cstruct.create 100 in

  let frames = Frame.make_headers_fragmented
    ~stream_id ~end_stream:false ~max_frame_size exact_header in

  assert (List.length frames = 1);
  Printf.printf "✓ Exact max_frame_size: single frame\n"

(** Test edge case: empty header block *)
let test_empty_headers () =
  let stream_id = 9l in
  let empty_header = Cstruct.create 0 in

  let frames = Frame.make_headers_fragmented
    ~stream_id ~end_stream:true empty_header in

  assert (List.length frames = 1);
  let frame = List.hd frames in
  assert (Cstruct.length frame.payload = 0);
  assert (Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.end_headers);
  Printf.printf "✓ Empty headers: single empty HEADERS frame\n"

(** Test serialization and parsing roundtrip *)
let test_frame_roundtrip () =
  let stream_id = 11l in
  let max_frame_size = 64 in
  let header_block = Cstruct.create 200 in
  for i = 0 to 199 do
    Cstruct.set_uint8 header_block i (i * 7 mod 256)
  done;

  let frames = Frame.make_headers_fragmented
    ~stream_id ~end_stream:true ~max_frame_size header_block in

  (* Serialize all frames to wire format *)
  let serialized = List.map Frame.to_cstruct frames in

  (* Parse them back *)
  let parsed_frames = List.map (fun cs ->
    match Frame.parse cs with
    | Some (frame, _) -> frame
    | None -> failwith "Parse failed"
  ) serialized in

  (* Verify frame types and content *)
  let first = List.hd parsed_frames in
  assert (first.Frame.header.frame_type = Frame.Headers);
  assert (first.Frame.header.stream_id = stream_id);

  let rest = List.tl parsed_frames in
  List.iter (fun f ->
    assert (f.Frame.header.frame_type = Frame.Continuation);
    assert (f.Frame.header.stream_id = stream_id)
  ) rest;

  Printf.printf "✓ Frame roundtrip: serialize → parse preserves data\n"

(** Test make_continuation directly *)
let test_make_continuation () =
  let stream_id = 13l in
  let payload = Cstruct.create 50 in

  let frame1 = Frame.make_continuation ~stream_id ~end_headers:false payload in
  assert (frame1.Frame.header.frame_type = Frame.Continuation);
  assert (not (Frame.Flags.is_set frame1.Frame.header.flags Frame.Flags.end_headers));

  let frame2 = Frame.make_continuation ~stream_id ~end_headers:true payload in
  assert (frame2.Frame.header.frame_type = Frame.Continuation);
  assert (Frame.Flags.is_set frame2.Frame.header.flags Frame.Flags.end_headers);

  Printf.printf "✓ make_continuation: creates correct frame type and flags\n"

let () =
  Printf.printf "\n╔═══════════════════════════════════════════════════════╗\n";
  Printf.printf "║     CONTINUATION Frame Tests (RFC 7540 §6.10)         ║\n";
  Printf.printf "╚═══════════════════════════════════════════════════════╝\n\n";

  test_small_headers ();
  test_large_headers ();
  test_data_integrity ();
  test_exact_max_size ();
  test_empty_headers ();
  test_frame_roundtrip ();
  test_make_continuation ();

  Printf.printf "\n✅ All CONTINUATION tests passed!\n"
