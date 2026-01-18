(** Tests for streaming message extraction *)

(** Helper to unwrap encode result in tests *)
let encode_ok ~codec data =
  match Grpc_core.Message.encode ~codec data with
  | Ok frame -> frame
  | Error e -> failwith (Printf.sprintf "Unexpected encode error: %s" e)

(** Helper to unwrap extract_all result in tests *)
let extract_ok ~codec buf =
  match Grpc_core.Message.extract_all ~codec buf with
  | Ok (messages, remaining) -> (messages, remaining)
  | Error (Grpc_core.Message.Oversized len) ->
      failwith (Printf.sprintf "Unexpected oversized message: %d bytes" len)
  | Error (Grpc_core.Message.Decode_error msg) ->
      failwith (Printf.sprintf "Unexpected decode error: %s" msg)

let test_extract_single_message () =
  let msg = "hello" in
  let codec = Grpc_core.Codec.identity in
  let frame = encode_ok ~codec msg in

  let messages, remaining = extract_ok ~codec frame in
  assert (List.length messages = 1);
  assert (List.hd messages = "hello");
  assert (remaining = "");
  Printf.printf "  ✓ Single message extraction: OK\n%!"

let test_extract_multiple_messages () =
  let codec = Grpc_core.Codec.identity in
  let frame1 = encode_ok ~codec "msg1" in
  let frame2 = encode_ok ~codec "msg2" in
  let frame3 = encode_ok ~codec "msg3" in
  let combined = frame1 ^ frame2 ^ frame3 in

  let messages, remaining = extract_ok ~codec combined in
  assert (List.length messages = 3);
  assert (List.nth messages 0 = "msg1");
  assert (List.nth messages 1 = "msg2");
  assert (List.nth messages 2 = "msg3");
  assert (remaining = "");
  Printf.printf "  ✓ Multiple messages extraction: OK\n%!"

let test_extract_partial_message () =
  let codec = Grpc_core.Codec.identity in
  let frame = encode_ok ~codec "complete" in
  (* Take only first 3 bytes (header incomplete) *)
  let partial = String.sub frame 0 3 in

  let messages, remaining = extract_ok ~codec partial in
  assert (List.length messages = 0);
  assert (remaining = partial);
  Printf.printf "  ✓ Partial header handling: OK\n%!"

let test_extract_partial_body () =
  let codec = Grpc_core.Codec.identity in
  let frame = encode_ok ~codec "longmessage" in
  (* Take header (5 bytes) + only 4 bytes of body *)
  let partial = String.sub frame 0 9 in

  let messages, remaining = extract_ok ~codec partial in
  assert (List.length messages = 0);
  assert (remaining = partial);
  Printf.printf "  ✓ Partial body handling: OK\n%!"

let test_extract_mixed () =
  let codec = Grpc_core.Codec.identity in
  let frame1 = encode_ok ~codec "first" in
  let frame2 = encode_ok ~codec "secondmsg" in
  (* frame2 is incomplete - only take first 7 bytes (header + 2 bytes) *)
  let partial_frame2 = String.sub frame2 0 7 in
  let combined = frame1 ^ partial_frame2 in

  let messages, remaining = extract_ok ~codec combined in
  assert (List.length messages = 1);
  assert (List.hd messages = "first");
  assert (remaining = partial_frame2);
  Printf.printf "  ✓ Complete + partial message handling: OK\n%!"

let test_extract_empty_buffer () =
  let codec = Grpc_core.Codec.identity in
  let messages, remaining = extract_ok ~codec "" in
  assert (List.length messages = 0);
  assert (remaining = "");
  Printf.printf "  ✓ Empty buffer handling: OK\n%!"

let test_extract_empty_message () =
  let codec = Grpc_core.Codec.identity in
  let frame = encode_ok ~codec "" in

  let messages, remaining = extract_ok ~codec frame in
  assert (List.length messages = 1);
  assert (List.hd messages = "");
  assert (remaining = "");
  Printf.printf "  ✓ Empty message extraction: OK\n%!"

let test_streaming_accumulation () =
  (* Simulate network chunks arriving piece by piece *)
  let codec = Grpc_core.Codec.identity in
  let frame1 = encode_ok ~codec "chunk1" in
  let frame2 = encode_ok ~codec "chunk2" in
  let full_data = frame1 ^ frame2 in

  (* Simulate receiving data in arbitrary chunks *)
  let chunk_sizes = [3; 5; 4; 6; 4] in  (* Split 22 bytes into chunks *)
  let buffer = ref "" in
  let extracted = ref [] in
  let pos = ref 0 in

  List.iter (fun size ->
    let chunk = String.sub full_data !pos (min size (String.length full_data - !pos)) in
    buffer := !buffer ^ chunk;
    pos := !pos + size;

    let msgs, remaining = extract_ok ~codec !buffer in
    extracted := !extracted @ msgs;
    buffer := remaining
  ) chunk_sizes;

  assert (List.length !extracted = 2);
  assert (List.nth !extracted 0 = "chunk1");
  assert (List.nth !extracted 1 = "chunk2");
  assert (!buffer = "");
  Printf.printf "  ✓ Streaming accumulation simulation: OK\n%!"

let test_large_message () =
  let codec = Grpc_core.Codec.identity in
  (* Create a 10KB message *)
  let large_data = String.make 10240 'X' in
  let frame = encode_ok ~codec large_data in

  let messages, remaining = extract_ok ~codec frame in
  assert (List.length messages = 1);
  assert (List.hd messages = large_data);
  assert (remaining = "");
  Printf.printf "  ✓ Large message (10KB) extraction: OK\n%!"

(** Test oversized message rejection *)
let test_extract_oversized () =
  let codec = Grpc_core.Codec.identity in
  (* Create a message that exceeds max_size *)
  let large_data = String.make 1000 'X' in
  let frame = encode_ok ~codec large_data in

  (* Use very small max_size to trigger error *)
  match Grpc_core.Message.extract_all ~max_size:100 ~codec frame with
  | Error (Grpc_core.Message.Oversized len) ->
      assert (len = 1000);
      Printf.printf "  ✓ Oversized message rejection: OK\n%!"
  | Ok _ ->
      failwith "Expected Oversized error"
  | Error (Grpc_core.Message.Decode_error _) ->
      failwith "Expected Oversized, got Decode_error"

let () =
  Printf.printf "\n=== grpc-streaming tests ===\n\n%!";

  Printf.printf "📦 Message extraction tests:\n%!";
  test_extract_single_message ();
  test_extract_multiple_messages ();
  test_extract_partial_message ();
  test_extract_partial_body ();
  test_extract_mixed ();
  test_extract_empty_buffer ();
  test_extract_empty_message ();
  test_extract_oversized ();

  Printf.printf "\n📡 Streaming simulation tests:\n%!";
  test_streaming_accumulation ();
  test_large_message ();

  Printf.printf "\n=== All streaming tests passed! ===\n%!"
