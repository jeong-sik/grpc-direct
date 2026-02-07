(** Tests for H2_lite.Grpc_message — gRPC message framing over HTTP/2 *)

open H2_lite

(* ── Constants ────────────────────────────────────────────────── *)

let test_header_size () =
  assert (Grpc_message.header_size = 5);
  Printf.printf "PASS header_size = 5\n%!"
;;

(* ── encode / decode roundtrip ────────────────────────────────── *)

let test_encode_decode_basic () =
  let body = Cstruct.of_string "Hello, gRPC" in
  let encoded = Grpc_message.encode body in
  assert (Cstruct.length encoded = 5 + 11);
  (* Compressed flag = 0 *)
  assert (Cstruct.get_uint8 encoded 0 = 0);
  (* Length = 11 *)
  assert (Cstruct.BE.get_uint32 encoded 1 = 11l);
  let decoded, remaining = Grpc_message.decode encoded in
  assert (Cstruct.to_string decoded = "Hello, gRPC");
  assert (Cstruct.length remaining = 0);
  Printf.printf "PASS encode/decode basic\n%!"
;;

let test_encode_compressed_flag () =
  let body = Cstruct.of_string "compressed" in
  let encoded = Grpc_message.encode ~compressed:true body in
  assert (Cstruct.get_uint8 encoded 0 = 1);
  let encoded2 = Grpc_message.encode ~compressed:false body in
  assert (Cstruct.get_uint8 encoded2 0 = 0);
  Printf.printf "PASS encode compressed flag\n%!"
;;

let test_encode_empty_body () =
  let body = Cstruct.create 0 in
  let encoded = Grpc_message.encode body in
  assert (Cstruct.length encoded = 5);
  assert (Cstruct.get_uint8 encoded 0 = 0);
  assert (Cstruct.BE.get_uint32 encoded 1 = 0l);
  let decoded, remaining = Grpc_message.decode encoded in
  assert (Cstruct.length decoded = 0);
  assert (Cstruct.length remaining = 0);
  Printf.printf "PASS encode/decode empty body\n%!"
;;

let test_encode_decode_large () =
  let size = 16384 in
  let body = Cstruct.create size in
  for i = 0 to size - 1 do
    Cstruct.set_uint8 body i (i land 0xFF)
  done;
  let encoded = Grpc_message.encode body in
  assert (Cstruct.length encoded = 5 + size);
  let decoded, remaining = Grpc_message.decode encoded in
  assert (Cstruct.length remaining = 0);
  assert (Cstruct.length decoded = size);
  for i = 0 to size - 1 do
    assert (Cstruct.get_uint8 decoded i = i land 0xFF)
  done;
  Printf.printf "PASS encode/decode large (%d bytes)\n%!" size
;;

(* ── decode error cases ───────────────────────────────────────── *)

let test_decode_incomplete_header () =
  let buf = Cstruct.create 3 in
  (try
     let _ = Grpc_message.decode buf in
     assert false
   with
   | Failure _ -> ());
  Printf.printf "PASS decode rejects incomplete header\n%!"
;;

let test_decode_incomplete_body () =
  (* Header says 100 bytes, but only provide 50 *)
  let buf = Cstruct.create (5 + 50) in
  Cstruct.set_uint8 buf 0 0;
  Cstruct.BE.set_uint32 buf 1 100l;
  (try
     let _ = Grpc_message.decode buf in
     assert false
   with
   | Failure _ -> ());
  Printf.printf "PASS decode rejects incomplete body\n%!"
;;

(* ── decode with remaining bytes ──────────────────────────────── *)

let test_decode_with_remaining () =
  let msg1 = Grpc_message.encode (Cstruct.of_string "msg1") in
  let msg2 = Grpc_message.encode (Cstruct.of_string "msg2") in
  let combined = Cstruct.concat [ msg1; msg2 ] in
  let decoded1, remaining = Grpc_message.decode combined in
  assert (Cstruct.to_string decoded1 = "msg1");
  assert (Cstruct.length remaining = Cstruct.length msg2);
  let decoded2, remaining2 = Grpc_message.decode remaining in
  assert (Cstruct.to_string decoded2 = "msg2");
  assert (Cstruct.length remaining2 = 0);
  Printf.printf "PASS decode with remaining (multiple messages)\n%!"
;;

(* ── try_decode ───────────────────────────────────────────────── *)

let test_try_decode_complete () =
  let body = Cstruct.of_string "complete" in
  let encoded = Grpc_message.encode body in
  (match Grpc_message.try_decode encoded with
   | Some (decoded, remaining) ->
     assert (Cstruct.to_string decoded = "complete");
     assert (Cstruct.length remaining = 0)
   | None -> assert false);
  Printf.printf "PASS try_decode complete\n%!"
;;

let test_try_decode_incomplete_header () =
  let buf = Cstruct.create 3 in
  assert (Grpc_message.try_decode buf = None);
  Printf.printf "PASS try_decode returns None for incomplete header\n%!"
;;

let test_try_decode_incomplete_body () =
  let buf = Cstruct.create (5 + 10) in
  Cstruct.set_uint8 buf 0 0;
  Cstruct.BE.set_uint32 buf 1 100l;
  (* Says 100 bytes, but only 10 available *)
  assert (Grpc_message.try_decode buf = None);
  Printf.printf "PASS try_decode returns None for incomplete body\n%!"
;;

let test_try_decode_with_remaining () =
  let msg = Grpc_message.encode (Cstruct.of_string "data") in
  let extra = Cstruct.of_string "extra" in
  let combined = Cstruct.concat [ msg; extra ] in
  (match Grpc_message.try_decode combined with
   | Some (decoded, remaining) ->
     assert (Cstruct.to_string decoded = "data");
     assert (Cstruct.to_string remaining = "extra")
   | None -> assert false);
  Printf.printf "PASS try_decode with remaining\n%!"
;;

(* ── is_complete ──────────────────────────────────────────────── *)

let test_is_complete_true () =
  let encoded = Grpc_message.encode (Cstruct.of_string "ok") in
  assert (Grpc_message.is_complete encoded);
  Printf.printf "PASS is_complete true\n%!"
;;

let test_is_complete_false_header () =
  let buf = Cstruct.create 2 in
  assert (not (Grpc_message.is_complete buf));
  Printf.printf "PASS is_complete false (incomplete header)\n%!"
;;

let test_is_complete_false_body () =
  let buf = Cstruct.create (5 + 5) in
  Cstruct.set_uint8 buf 0 0;
  Cstruct.BE.set_uint32 buf 1 100l;
  assert (not (Grpc_message.is_complete buf));
  Printf.printf "PASS is_complete false (incomplete body)\n%!"
;;

let test_is_complete_exact () =
  let encoded = Grpc_message.encode (Cstruct.of_string "exact") in
  assert (Grpc_message.is_complete encoded);
  Printf.printf "PASS is_complete exact size\n%!"
;;

let test_is_complete_with_extra () =
  let msg = Grpc_message.encode (Cstruct.of_string "msg") in
  let combined = Cstruct.concat [ msg; Cstruct.of_string "extra" ] in
  assert (Grpc_message.is_complete combined);
  Printf.printf "PASS is_complete with extra data\n%!"
;;

(* ── expected_size ────────────────────────────────────────────── *)

let test_expected_size () =
  let encoded = Grpc_message.encode (Cstruct.of_string "test") in
  (match Grpc_message.expected_size encoded with
   | Some sz -> assert (sz = 5 + 4)
   | None -> assert false);
  Printf.printf "PASS expected_size\n%!"
;;

let test_expected_size_incomplete () =
  let buf = Cstruct.create 3 in
  assert (Grpc_message.expected_size buf = None);
  Printf.printf "PASS expected_size returns None for incomplete header\n%!"
;;

let test_expected_size_empty_body () =
  let encoded = Grpc_message.encode (Cstruct.create 0) in
  (match Grpc_message.expected_size encoded with
   | Some sz -> assert (sz = 5)
   | None -> assert false);
  Printf.printf "PASS expected_size empty body\n%!"
;;

(* ── Status module ────────────────────────────────────────────── *)

let test_status_to_int () =
  assert (Grpc_message.Status.to_int Grpc_message.Status.Ok = 0);
  assert (Grpc_message.Status.to_int Cancelled = 1);
  assert (Grpc_message.Status.to_int Unknown = 2);
  assert (Grpc_message.Status.to_int InvalidArgument = 3);
  assert (Grpc_message.Status.to_int DeadlineExceeded = 4);
  assert (Grpc_message.Status.to_int NotFound = 5);
  assert (Grpc_message.Status.to_int AlreadyExists = 6);
  assert (Grpc_message.Status.to_int PermissionDenied = 7);
  assert (Grpc_message.Status.to_int ResourceExhausted = 8);
  assert (Grpc_message.Status.to_int FailedPrecondition = 9);
  assert (Grpc_message.Status.to_int Aborted = 10);
  assert (Grpc_message.Status.to_int OutOfRange = 11);
  assert (Grpc_message.Status.to_int Unimplemented = 12);
  assert (Grpc_message.Status.to_int Internal = 13);
  assert (Grpc_message.Status.to_int Unavailable = 14);
  assert (Grpc_message.Status.to_int DataLoss = 15);
  assert (Grpc_message.Status.to_int Unauthenticated = 16);
  Printf.printf "PASS Status.to_int\n%!"
;;

let test_status_of_int () =
  for i = 0 to 16 do
    let s = Grpc_message.Status.of_int i in
    assert (Grpc_message.Status.to_int s = i)
  done;
  (* Unknown code maps to Unknown *)
  let s = Grpc_message.Status.of_int 99 in
  assert (Grpc_message.Status.to_int s = 2);
  (* Unknown = 2 *)
  Printf.printf "PASS Status.of_int roundtrip\n%!"
;;

let test_status_to_string () =
  assert (Grpc_message.Status.to_string Grpc_message.Status.Ok = "OK");
  assert (Grpc_message.Status.to_string Cancelled = "CANCELLED");
  assert (Grpc_message.Status.to_string NotFound = "NOT_FOUND");
  assert (Grpc_message.Status.to_string Unimplemented = "UNIMPLEMENTED");
  assert (Grpc_message.Status.to_string Unauthenticated = "UNAUTHENTICATED");
  Printf.printf "PASS Status.to_string\n%!"
;;

let test_status_roundtrip_all () =
  let all_statuses =
    [ Grpc_message.Status.Ok
    ; Cancelled
    ; Unknown
    ; InvalidArgument
    ; DeadlineExceeded
    ; NotFound
    ; AlreadyExists
    ; PermissionDenied
    ; ResourceExhausted
    ; FailedPrecondition
    ; Aborted
    ; OutOfRange
    ; Unimplemented
    ; Internal
    ; Unavailable
    ; DataLoss
    ; Unauthenticated
    ]
  in
  List.iter
    (fun s ->
       let i = Grpc_message.Status.to_int s in
       let s' = Grpc_message.Status.of_int i in
       assert (Grpc_message.Status.to_int s' = i);
       let str = Grpc_message.Status.to_string s in
       assert (String.length str > 0))
    all_statuses;
  Printf.printf "PASS Status roundtrip all codes\n%!"
;;

(* ── Multiple message framing ─────────────────────────────────── *)

let test_multiple_message_framing () =
  let messages = [ "first"; "second"; "third"; "" ] in
  let encoded = List.map (fun s -> Grpc_message.encode (Cstruct.of_string s)) messages in
  let combined = Cstruct.concat encoded in
  (* Decode all messages in sequence *)
  let decoded = ref [] in
  let buf = ref combined in
  while Grpc_message.is_complete !buf do
    let msg, rest = Grpc_message.decode !buf in
    decoded := Cstruct.to_string msg :: !decoded;
    buf := rest
  done;
  let decoded = List.rev !decoded in
  assert (decoded = messages);
  Printf.printf "PASS multiple message framing\n%!"
;;

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Printf.printf "\n=== gRPC Message Tests ===\n\n%!";
  test_header_size ();
  test_encode_decode_basic ();
  test_encode_compressed_flag ();
  test_encode_empty_body ();
  test_encode_decode_large ();
  test_decode_incomplete_header ();
  test_decode_incomplete_body ();
  test_decode_with_remaining ();
  test_try_decode_complete ();
  test_try_decode_incomplete_header ();
  test_try_decode_incomplete_body ();
  test_try_decode_with_remaining ();
  test_is_complete_true ();
  test_is_complete_false_header ();
  test_is_complete_false_body ();
  test_is_complete_exact ();
  test_is_complete_with_extra ();
  test_expected_size ();
  test_expected_size_incomplete ();
  test_expected_size_empty_body ();
  test_status_to_int ();
  test_status_of_int ();
  test_status_to_string ();
  test_status_roundtrip_all ();
  test_multiple_message_framing ();
  Printf.printf "\n=== All gRPC Message tests passed. ===\n%!"
;;
