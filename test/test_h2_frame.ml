(** Tests for H2_lite.Frame — HTTP/2 frame encoding/decoding (RFC 7540 Section 4) *)

open H2_lite

(* ── frame_type conversion roundtrip ──────────────────────────── *)

let test_frame_type_roundtrip () =
  let types =
    [ Frame.Data
    ; Headers
    ; Priority
    ; RstStream
    ; Settings
    ; PushPromise
    ; Ping
    ; GoAway
    ; WindowUpdate
    ; Continuation
    ; Unknown 42
    ]
  in
  List.iter
    (fun ft ->
       let n = Frame.int_of_frame_type ft in
       let ft' = Frame.frame_type_of_int n in
       assert (Frame.int_of_frame_type ft' = n))
    types;
  Printf.printf "PASS frame_type_of_int / int_of_frame_type roundtrip\n%!"
;;

let test_frame_type_known_values () =
  assert (Frame.frame_type_of_int 0 = Data);
  assert (Frame.frame_type_of_int 1 = Headers);
  assert (Frame.frame_type_of_int 4 = Settings);
  assert (Frame.frame_type_of_int 6 = Ping);
  assert (Frame.frame_type_of_int 7 = GoAway);
  assert (Frame.frame_type_of_int 8 = WindowUpdate);
  assert (Frame.frame_type_of_int 9 = Continuation);
  assert (Frame.frame_type_of_int 99 = Unknown 99);
  Printf.printf "PASS frame_type known values\n%!"
;;

(* ── Flags ────────────────────────────────────────────────────── *)

let test_flags () =
  assert (Frame.Flags.is_set 0x01 Frame.Flags.end_stream);
  assert (not (Frame.Flags.is_set 0x02 Frame.Flags.end_stream));
  assert (Frame.Flags.is_set 0x04 Frame.Flags.end_headers);
  assert (Frame.Flags.is_set 0x08 Frame.Flags.padded);
  assert (Frame.Flags.is_set 0x20 Frame.Flags.priority);
  assert (Frame.Flags.is_set 0x01 Frame.Flags.ack);
  (* Combined flags *)
  let combined = Frame.Flags.end_stream lor Frame.Flags.end_headers in
  assert (Frame.Flags.is_set combined Frame.Flags.end_stream);
  assert (Frame.Flags.is_set combined Frame.Flags.end_headers);
  assert (not (Frame.Flags.is_set combined Frame.Flags.padded));
  Printf.printf "PASS flags is_set\n%!"
;;

(* ── parse_header ─────────────────────────────────────────────── *)

let test_parse_header_basic () =
  let buf = Cstruct.create 9 in
  (* Length = 256 = 0x000100 *)
  Cstruct.set_uint8 buf 0 0;
  Cstruct.set_uint8 buf 1 1;
  Cstruct.set_uint8 buf 2 0;
  (* Type = HEADERS (1) *)
  Cstruct.set_uint8 buf 3 1;
  (* Flags = END_STREAM | END_HEADERS = 0x05 *)
  Cstruct.set_uint8 buf 4 0x05;
  (* Stream ID = 3 *)
  Cstruct.BE.set_uint32 buf 5 3l;
  let hdr, rest = Frame.parse_header buf in
  assert (hdr.length = 256);
  assert (hdr.frame_type = Headers);
  assert (hdr.flags = 0x05);
  assert (hdr.stream_id = 3l);
  assert (Cstruct.length rest = 0);
  Printf.printf "PASS parse_header basic\n%!"
;;

let test_parse_header_stream_id_mask () =
  (* The reserved bit (high bit) of stream_id should be masked off *)
  let buf = Cstruct.create 9 in
  Cstruct.set_uint8 buf 0 0;
  Cstruct.set_uint8 buf 1 0;
  Cstruct.set_uint8 buf 2 0;
  Cstruct.set_uint8 buf 3 0;
  Cstruct.set_uint8 buf 4 0;
  (* Set all 32 bits including the reserved bit *)
  Cstruct.BE.set_uint32 buf 5 0xFFFFFFFFl;
  let hdr, _ = Frame.parse_header buf in
  assert (hdr.stream_id = 0x7FFFFFFFl);
  Printf.printf "PASS parse_header stream_id mask\n%!"
;;

let test_parse_header_too_small () =
  let buf = Cstruct.create 5 in
  (try
     let _ = Frame.parse_header buf in
     assert false
   with
   | Invalid_argument _ -> ());
  Printf.printf "PASS parse_header rejects small buffer\n%!"
;;

(* ── write_header ─────────────────────────────────────────────── *)

let test_write_header () =
  let hdr : Frame.header =
    { length = 0x123; frame_type = Settings; flags = 0x01; stream_id = 0l }
  in
  let buf = Cstruct.create 9 in
  Frame.write_header buf hdr;
  let hdr', _ = Frame.parse_header buf in
  assert (hdr'.length = hdr.length);
  assert (hdr'.frame_type = Settings);
  assert (hdr'.flags = 0x01);
  assert (hdr'.stream_id = 0l);
  Printf.printf "PASS write_header roundtrip\n%!"
;;

(* ── parse (full frame) ──────────────────────────────────────── *)

let test_parse_complete () =
  let payload = Cstruct.of_string "hello" in
  let frame = Frame.make_data ~stream_id:1l ~end_stream:false payload in
  let wire = Frame.to_cstruct frame in
  (match Frame.parse wire with
   | Some (f, rem) ->
     assert (Cstruct.length rem = 0);
     assert (f.header.length = 5);
     assert (f.header.frame_type = Data);
     assert (Cstruct.to_string f.payload = "hello")
   | None -> assert false);
  Printf.printf "PASS parse complete frame\n%!"
;;

let test_parse_incomplete_header () =
  let buf = Cstruct.create 5 in
  assert (Frame.parse buf = None);
  Printf.printf "PASS parse returns None for incomplete header\n%!"
;;

let test_parse_incomplete_payload () =
  (* Header says length=100, but only provide 50 bytes of payload *)
  let buf = Cstruct.create (9 + 50) in
  Cstruct.set_uint8 buf 0 0;
  Cstruct.set_uint8 buf 1 0;
  Cstruct.set_uint8 buf 2 100;
  Cstruct.set_uint8 buf 3 0;
  Cstruct.set_uint8 buf 4 0;
  Cstruct.BE.set_uint32 buf 5 1l;
  assert (Frame.parse buf = None);
  Printf.printf "PASS parse returns None for incomplete payload\n%!"
;;

let test_parse_with_remaining () =
  let payload = Cstruct.of_string "abc" in
  let frame = Frame.make_data ~stream_id:1l ~end_stream:true payload in
  let wire = Frame.to_cstruct frame in
  let extra = Cstruct.of_string "extra" in
  let combined = Cstruct.concat [ wire; extra ] in
  (match Frame.parse combined with
   | Some (f, rem) ->
     assert (Cstruct.to_string f.payload = "abc");
     assert (Cstruct.to_string rem = "extra")
   | None -> assert false);
  Printf.printf "PASS parse with remaining bytes\n%!"
;;

(* ── make_data ────────────────────────────────────────────────── *)

let test_make_data_end_stream () =
  let p = Cstruct.of_string "data" in
  let f = Frame.make_data ~stream_id:7l ~end_stream:true p in
  assert (Frame.Flags.is_set f.header.flags Frame.Flags.end_stream);
  assert (f.header.frame_type = Data);
  assert (f.header.stream_id = 7l);
  assert (f.header.length = 4);
  let f2 = Frame.make_data ~stream_id:7l ~end_stream:false p in
  assert (not (Frame.Flags.is_set f2.header.flags Frame.Flags.end_stream));
  Printf.printf "PASS make_data end_stream flag\n%!"
;;

let test_make_data_empty () =
  let p = Cstruct.create 0 in
  let f = Frame.make_data ~stream_id:1l ~end_stream:true p in
  assert (f.header.length = 0);
  Printf.printf "PASS make_data empty payload\n%!"
;;

(* ── make_headers ─────────────────────────────────────────────── *)

let test_make_headers_flags () =
  let p = Cstruct.of_string "hdr" in
  let f1 = Frame.make_headers ~stream_id:1l ~end_stream:true ~end_headers:true p in
  assert (Frame.Flags.is_set f1.header.flags Frame.Flags.end_stream);
  assert (Frame.Flags.is_set f1.header.flags Frame.Flags.end_headers);
  let f2 = Frame.make_headers ~stream_id:1l ~end_stream:false ~end_headers:false p in
  assert (not (Frame.Flags.is_set f2.header.flags Frame.Flags.end_stream));
  assert (not (Frame.Flags.is_set f2.header.flags Frame.Flags.end_headers));
  Printf.printf "PASS make_headers flag combinations\n%!"
;;

(* ── make_headers_with_priority ──────────────────────────────── *)

let test_make_headers_with_priority () =
  let p = Cstruct.of_string "hdr" in
  let priority : Frame.priority_info =
    { exclusive = true; dependency = 0l; weight = 128 }
  in
  let f =
    Frame.make_headers_with_priority
      ~stream_id:3l
      ~end_stream:false
      ~end_headers:true
      ~priority
      p
  in
  assert (f.header.frame_type = Headers);
  assert (Frame.Flags.is_set f.header.flags Frame.Flags.priority);
  assert (Frame.Flags.is_set f.header.flags Frame.Flags.end_headers);
  assert (not (Frame.Flags.is_set f.header.flags Frame.Flags.end_stream));
  (* payload = 5 bytes priority + 3 bytes "hdr" *)
  assert (f.header.length = 8);
  Printf.printf "PASS make_headers_with_priority\n%!"
;;

let test_make_headers_with_priority_weight_bounds () =
  let p = Cstruct.of_string "x" in
  let pri w : Frame.priority_info = { exclusive = false; dependency = 0l; weight = w } in
  (* weight = 1 is valid (minimum) *)
  let _ =
    Frame.make_headers_with_priority
      ~stream_id:1l
      ~end_stream:false
      ~end_headers:true
      ~priority:(pri 1)
      p
  in
  (* weight = 256 is valid (maximum) *)
  let _ =
    Frame.make_headers_with_priority
      ~stream_id:1l
      ~end_stream:false
      ~end_headers:true
      ~priority:(pri 256)
      p
  in
  (* weight = 0 is invalid *)
  (try
     let _ =
       Frame.make_headers_with_priority
         ~stream_id:1l
         ~end_stream:false
         ~end_headers:true
         ~priority:(pri 0)
         p
     in
     assert false
   with
   | Invalid_argument _ -> ());
  (* weight = 257 is invalid *)
  (try
     let _ =
       Frame.make_headers_with_priority
         ~stream_id:1l
         ~end_stream:false
         ~end_headers:true
         ~priority:(pri 257)
         p
     in
     assert false
   with
   | Invalid_argument _ -> ());
  Printf.printf "PASS make_headers_with_priority weight bounds\n%!"
;;

(* ── make_priority / parse_priority ──────────────────────────── *)

let test_priority_roundtrip () =
  let pri : Frame.priority_info = { exclusive = true; dependency = 5l; weight = 200 } in
  let frame = Frame.make_priority ~stream_id:3l pri in
  assert (frame.header.frame_type = Priority);
  assert (frame.header.length = 5);
  let parsed, off = Frame.parse_priority frame.payload ~offset:0 in
  assert (parsed.exclusive = true);
  assert (parsed.dependency = 5l);
  assert (parsed.weight = 200);
  assert (off = 5);
  Printf.printf "PASS priority roundtrip\n%!"
;;

let test_priority_non_exclusive () =
  let pri : Frame.priority_info = { exclusive = false; dependency = 10l; weight = 1 } in
  let frame = Frame.make_priority ~stream_id:1l pri in
  let parsed, _ = Frame.parse_priority frame.payload ~offset:0 in
  assert (parsed.exclusive = false);
  assert (parsed.dependency = 10l);
  assert (parsed.weight = 1);
  Printf.printf "PASS priority non-exclusive\n%!"
;;

let test_parse_priority_too_small () =
  let buf = Cstruct.create 3 in
  (try
     let _ = Frame.parse_priority buf ~offset:0 in
     assert false
   with
   | Invalid_argument _ -> ());
  Printf.printf "PASS parse_priority rejects small payload\n%!"
;;

(* ── make_rst_stream ──────────────────────────────────────────── *)

let test_make_rst_stream () =
  let f = Frame.make_rst_stream ~stream_id:5l ~error_code:Frame.Error_code.cancel in
  assert (f.header.frame_type = RstStream);
  assert (f.header.length = 4);
  assert (f.header.stream_id = 5l);
  let parsed_code = Cstruct.BE.get_uint32 f.payload 0 in
  assert (parsed_code = 8l);
  Printf.printf "PASS make_rst_stream\n%!"
;;

let test_rst_stream_roundtrip () =
  let codes =
    [ Frame.Error_code.no_error
    ; Frame.Error_code.protocol_error
    ; Frame.Error_code.internal_error
    ; Frame.Error_code.flow_control_error
    ; Frame.Error_code.cancel
    ; Frame.Error_code.compression_error
    ; Frame.Error_code.http_1_1_required
    ]
  in
  List.iter
    (fun code ->
       let f = Frame.make_rst_stream ~stream_id:1l ~error_code:code in
       let wire = Frame.to_cstruct f in
       match Frame.parse wire with
       | Some (f', _) ->
         assert (f'.header.frame_type = RstStream);
         assert (Cstruct.BE.get_uint32 f'.payload 0 = code)
       | None -> assert false)
    codes;
  Printf.printf "PASS rst_stream roundtrip for all error codes\n%!"
;;

(* ── make_ping ────────────────────────────────────────────────── *)

let test_make_ping () =
  let data = Cstruct.create 8 in
  for i = 0 to 7 do
    Cstruct.set_uint8 data i (i * 3)
  done;
  let ping = Frame.make_ping ~ack:false data in
  assert (ping.header.frame_type = Ping);
  assert (ping.header.length = 8);
  assert (ping.header.stream_id = 0l);
  assert (not (Frame.Flags.is_set ping.header.flags Frame.Flags.ack));
  let pong = Frame.make_ping ~ack:true data in
  assert (Frame.Flags.is_set pong.header.flags Frame.Flags.ack);
  Printf.printf "PASS make_ping\n%!"
;;

let test_ping_roundtrip () =
  let data = Cstruct.create 8 in
  for i = 0 to 7 do
    Cstruct.set_uint8 data i (0xFF - i)
  done;
  let ping = Frame.make_ping ~ack:false data in
  let wire = Frame.to_cstruct ping in
  (match Frame.parse wire with
   | Some (f, _) ->
     assert (f.header.frame_type = Ping);
     for i = 0 to 7 do
       assert (Cstruct.get_uint8 f.payload i = 0xFF - i)
     done
   | None -> assert false);
  Printf.printf "PASS ping roundtrip\n%!"
;;

(* ── make_settings ────────────────────────────────────────────── *)

let test_make_settings () =
  let settings =
    [ Frame.Settings_id.initial_window_size, 32768l
    ; Frame.Settings_id.max_frame_size, 16384l
    ]
  in
  let f = Frame.make_settings ~ack:false settings in
  assert (f.header.frame_type = Settings);
  assert (f.header.length = 12);
  (* 2 settings * 6 bytes each *)
  assert (f.header.stream_id = 0l);
  assert (not (Frame.Flags.is_set f.header.flags Frame.Flags.ack));
  (* Verify first setting *)
  assert (Cstruct.BE.get_uint16 f.payload 0 = Frame.Settings_id.initial_window_size);
  assert (Cstruct.BE.get_uint32 f.payload 2 = 32768l);
  Printf.printf "PASS make_settings\n%!"
;;

let test_make_settings_ack () =
  let f = Frame.make_settings ~ack:true [] in
  assert (Frame.Flags.is_set f.header.flags Frame.Flags.ack);
  assert (f.header.length = 0);
  Printf.printf "PASS make_settings ack\n%!"
;;

let test_settings_roundtrip () =
  let settings =
    [ Frame.Settings_id.header_table_size, 8192l
    ; Frame.Settings_id.enable_push, 0l
    ; Frame.Settings_id.max_concurrent_streams, 100l
    ]
  in
  let f = Frame.make_settings ~ack:false settings in
  let wire = Frame.to_cstruct f in
  (match Frame.parse wire with
   | Some (f', _) ->
     assert (f'.header.frame_type = Settings);
     assert (f'.header.length = 18);
     (* Read back settings *)
     assert (Cstruct.BE.get_uint16 f'.payload 0 = Frame.Settings_id.header_table_size);
     assert (Cstruct.BE.get_uint32 f'.payload 2 = 8192l);
     assert (Cstruct.BE.get_uint16 f'.payload 6 = Frame.Settings_id.enable_push);
     assert (Cstruct.BE.get_uint32 f'.payload 8 = 0l)
   | None -> assert false);
  Printf.printf "PASS settings roundtrip\n%!"
;;

(* ── make_window_update ───────────────────────────────────────── *)

let test_make_window_update () =
  let f = Frame.make_window_update ~stream_id:0l ~increment:65535l in
  assert (f.header.frame_type = WindowUpdate);
  assert (f.header.length = 4);
  assert (f.header.stream_id = 0l);
  let inc = Cstruct.BE.get_uint32 f.payload 0 in
  assert (inc = 65535l);
  Printf.printf "PASS make_window_update\n%!"
;;

let test_window_update_stream () =
  let f = Frame.make_window_update ~stream_id:3l ~increment:1000l in
  assert (f.header.stream_id = 3l);
  let inc = Cstruct.BE.get_uint32 f.payload 0 in
  assert (inc = 1000l);
  Printf.printf "PASS make_window_update stream-level\n%!"
;;

let test_window_update_roundtrip () =
  let f = Frame.make_window_update ~stream_id:5l ~increment:0x7FFF0000l in
  let wire = Frame.to_cstruct f in
  (match Frame.parse wire with
   | Some (f', _) ->
     assert (f'.header.frame_type = WindowUpdate);
     let inc = Cstruct.BE.get_uint32 f'.payload 0 in
     assert (Int32.logand inc 0x7FFFFFFFl = 0x7FFF0000l)
   | None -> assert false);
  Printf.printf "PASS window_update roundtrip\n%!"
;;

(* ── make_goaway ──────────────────────────────────────────────── *)

let test_make_goaway () =
  let f =
    Frame.make_goaway
      ~last_stream_id:5l
      ~error_code:Frame.Error_code.no_error
      ~debug_data:"test"
  in
  assert (f.header.frame_type = GoAway);
  assert (f.header.length = 12);
  (* 4 + 4 + 4 *)
  assert (f.header.stream_id = 0l);
  let last_id = Cstruct.BE.get_uint32 f.payload 0 in
  assert (last_id = 5l);
  let ec = Cstruct.BE.get_uint32 f.payload 4 in
  assert (ec = Frame.Error_code.no_error);
  Printf.printf "PASS make_goaway\n%!"
;;

let test_goaway_debug_data () =
  let debug = "connection error details" in
  let f =
    Frame.make_goaway
      ~last_stream_id:7l
      ~error_code:Frame.Error_code.protocol_error
      ~debug_data:debug
  in
  assert (f.header.length = 8 + String.length debug);
  let got = Cstruct.to_string (Cstruct.sub f.payload 8 (String.length debug)) in
  assert (got = debug);
  Printf.printf "PASS goaway debug_data\n%!"
;;

let test_goaway_empty_debug () =
  let f =
    Frame.make_goaway
      ~last_stream_id:0l
      ~error_code:Frame.Error_code.no_error
      ~debug_data:""
  in
  assert (f.header.length = 8);
  Printf.printf "PASS goaway empty debug\n%!"
;;

let test_goaway_roundtrip () =
  let f =
    Frame.make_goaway
      ~last_stream_id:99l
      ~error_code:Frame.Error_code.enhance_your_calm
      ~debug_data:"rate limit"
  in
  let wire = Frame.to_cstruct f in
  (match Frame.parse wire with
   | Some (f', _) ->
     assert (f'.header.frame_type = GoAway);
     assert (Cstruct.BE.get_uint32 f'.payload 0 = 99l);
     assert (Cstruct.BE.get_uint32 f'.payload 4 = Frame.Error_code.enhance_your_calm);
     let dbg = Cstruct.to_string (Cstruct.sub f'.payload 8 10) in
     assert (dbg = "rate limit")
   | None -> assert false);
  Printf.printf "PASS goaway roundtrip\n%!"
;;

(* ── make_push_promise ────────────────────────────────────────── *)

let test_make_push_promise () =
  let hdr_block = Cstruct.of_string "headers" in
  let f =
    Frame.make_push_promise
      ~stream_id:1l
      ~promised_stream_id:2l
      ~end_headers:true
      hdr_block
  in
  assert (f.header.frame_type = PushPromise);
  assert (f.header.length = 4 + 7);
  assert (Frame.Flags.is_set f.header.flags Frame.Flags.end_headers);
  let promised = Cstruct.BE.get_uint32 f.payload 0 in
  assert (promised = 2l);
  Printf.printf "PASS make_push_promise\n%!"
;;

(* ── make_continuation ────────────────────────────────────────── *)

let test_make_continuation () =
  let p = Cstruct.of_string "continuation data" in
  let f = Frame.make_continuation ~stream_id:1l ~end_headers:false p in
  assert (f.header.frame_type = Continuation);
  assert (not (Frame.Flags.is_set f.header.flags Frame.Flags.end_headers));
  let f2 = Frame.make_continuation ~stream_id:1l ~end_headers:true p in
  assert (Frame.Flags.is_set f2.header.flags Frame.Flags.end_headers);
  Printf.printf "PASS make_continuation\n%!"
;;

(* ── make_headers_fragmented ──────────────────────────────────── *)

let test_headers_fragmented_single () =
  let block = Cstruct.create 50 in
  let frames =
    Frame.make_headers_fragmented
      ~stream_id:1l
      ~end_stream:false
      ~max_frame_size:100
      block
  in
  assert (List.length frames = 1);
  let f = List.hd frames in
  assert (f.header.frame_type = Headers);
  assert (Frame.Flags.is_set f.header.flags Frame.Flags.end_headers);
  Printf.printf "PASS headers_fragmented single frame\n%!"
;;

let test_headers_fragmented_multi () =
  let block = Cstruct.create 250 in
  for i = 0 to 249 do
    Cstruct.set_uint8 block i (i mod 256)
  done;
  let frames =
    Frame.make_headers_fragmented ~stream_id:3l ~end_stream:true ~max_frame_size:100 block
  in
  assert (List.length frames = 3);
  (* First = HEADERS *)
  let first = List.hd frames in
  assert (first.header.frame_type = Headers);
  assert (not (Frame.Flags.is_set first.header.flags Frame.Flags.end_headers));
  assert (Frame.Flags.is_set first.header.flags Frame.Flags.end_stream);
  (* Middle = CONTINUATION without END_HEADERS *)
  let mid = List.nth frames 1 in
  assert (mid.header.frame_type = Continuation);
  assert (not (Frame.Flags.is_set mid.header.flags Frame.Flags.end_headers));
  (* Last = CONTINUATION with END_HEADERS *)
  let last = List.nth frames 2 in
  assert (last.header.frame_type = Continuation);
  assert (Frame.Flags.is_set last.header.flags Frame.Flags.end_headers);
  (* Data integrity *)
  let total_payload =
    List.fold_left (fun acc f -> acc + Cstruct.length f.Frame.payload) 0 frames
  in
  assert (total_payload = 250);
  Printf.printf "PASS headers_fragmented multi\n%!"
;;

let test_headers_fragmented_with_priority () =
  let block = Cstruct.create 200 in
  let pri : Frame.priority_info = { exclusive = false; dependency = 0l; weight = 16 } in
  let frames =
    Frame.make_headers_fragmented
      ~stream_id:1l
      ~end_stream:false
      ~max_frame_size:100
      ~priority:pri
      block
  in
  (* first frame gets max_frame_size - 5 (priority) = 95 bytes of header data,
     plus 5 priority = 100 total payload *)
  let first = List.hd frames in
  assert (first.header.frame_type = Headers);
  assert (Frame.Flags.is_set first.header.flags Frame.Flags.priority);
  (* The remaining 200 - 95 = 105 bytes split into continuation frames *)
  assert (List.length frames >= 2);
  Printf.printf "PASS headers_fragmented with priority\n%!"
;;

(* ── make_push_promise_fragmented ─────────────────────────────── *)

let test_push_promise_fragmented_single () =
  let block = Cstruct.create 50 in
  let frames =
    Frame.make_push_promise_fragmented
      ~stream_id:1l
      ~promised_stream_id:2l
      ~max_frame_size:100
      block
  in
  assert (List.length frames = 1);
  let f = List.hd frames in
  assert (f.header.frame_type = PushPromise);
  assert (Frame.Flags.is_set f.header.flags Frame.Flags.end_headers);
  Printf.printf "PASS push_promise_fragmented single\n%!"
;;

let test_push_promise_fragmented_multi () =
  let block = Cstruct.create 200 in
  let frames =
    Frame.make_push_promise_fragmented
      ~stream_id:1l
      ~promised_stream_id:2l
      ~max_frame_size:100
      block
  in
  assert (List.length frames >= 2);
  let first = List.hd frames in
  assert (first.header.frame_type = PushPromise);
  assert (not (Frame.Flags.is_set first.header.flags Frame.Flags.end_headers));
  let last = List.nth frames (List.length frames - 1) in
  assert (last.header.frame_type = Continuation);
  assert (Frame.Flags.is_set last.header.flags Frame.Flags.end_headers);
  Printf.printf "PASS push_promise_fragmented multi\n%!"
;;

(* ── to_cstruct ───────────────────────────────────────────────── *)

let test_to_cstruct_size () =
  let p = Cstruct.of_string "payload" in
  let f = Frame.make_data ~stream_id:1l ~end_stream:false p in
  let wire = Frame.to_cstruct f in
  assert (Cstruct.length wire = Frame.header_size + 7);
  Printf.printf "PASS to_cstruct size\n%!"
;;

(* ── Error_code / Settings_id constants ──────────────────────── *)

let test_error_codes () =
  assert (Frame.Error_code.no_error = 0l);
  assert (Frame.Error_code.protocol_error = 1l);
  assert (Frame.Error_code.internal_error = 2l);
  assert (Frame.Error_code.flow_control_error = 3l);
  assert (Frame.Error_code.settings_timeout = 4l);
  assert (Frame.Error_code.stream_closed = 5l);
  assert (Frame.Error_code.frame_size_error = 6l);
  assert (Frame.Error_code.refused_stream = 7l);
  assert (Frame.Error_code.cancel = 8l);
  assert (Frame.Error_code.compression_error = 9l);
  assert (Frame.Error_code.connect_error = 10l);
  assert (Frame.Error_code.enhance_your_calm = 11l);
  assert (Frame.Error_code.inadequate_security = 12l);
  assert (Frame.Error_code.http_1_1_required = 13l);
  Printf.printf "PASS error_code constants\n%!"
;;

let test_settings_ids () =
  assert (Frame.Settings_id.header_table_size = 0x1);
  assert (Frame.Settings_id.enable_push = 0x2);
  assert (Frame.Settings_id.max_concurrent_streams = 0x3);
  assert (Frame.Settings_id.initial_window_size = 0x4);
  assert (Frame.Settings_id.max_frame_size = 0x5);
  assert (Frame.Settings_id.max_header_list_size = 0x6);
  Printf.printf "PASS settings_id constants\n%!"
;;

(* ── All frame types roundtrip via serialize/parse ────────────── *)

let test_all_frame_types_roundtrip () =
  let frames =
    [ Frame.make_data ~stream_id:1l ~end_stream:true (Cstruct.of_string "data")
    ; Frame.make_headers
        ~stream_id:3l
        ~end_stream:false
        ~end_headers:true
        (Cstruct.of_string "hdr")
    ; Frame.make_rst_stream ~stream_id:5l ~error_code:Frame.Error_code.cancel
    ; Frame.make_ping ~ack:false (Cstruct.create 8)
    ; Frame.make_settings ~ack:false [ 0x4, 32768l ]
    ; Frame.make_window_update ~stream_id:0l ~increment:1000l
    ; Frame.make_goaway ~last_stream_id:0l ~error_code:0l ~debug_data:""
    ; Frame.make_continuation ~stream_id:1l ~end_headers:true (Cstruct.of_string "cont")
    ]
  in
  List.iter
    (fun f ->
       let wire = Frame.to_cstruct f in
       match Frame.parse wire with
       | Some (f', _) ->
         assert (
           Frame.int_of_frame_type f'.header.frame_type
           = Frame.int_of_frame_type f.header.frame_type);
         assert (f'.header.length = f.header.length);
         assert (f'.header.stream_id = f.header.stream_id)
       | None -> assert false)
    frames;
  Printf.printf "PASS all frame types roundtrip\n%!"
;;

(* ── Large payload roundtrip ──────────────────────────────────── *)

let test_large_payload_roundtrip () =
  let size = Frame.max_frame_size in
  let payload = Cstruct.create size in
  for i = 0 to size - 1 do
    Cstruct.set_uint8 payload i (i land 0xFF)
  done;
  let f = Frame.make_data ~stream_id:1l ~end_stream:false payload in
  let wire = Frame.to_cstruct f in
  (match Frame.parse wire with
   | Some (f', _) ->
     assert (f'.header.length = size);
     for i = 0 to size - 1 do
       assert (Cstruct.get_uint8 f'.payload i = i land 0xFF)
     done
   | None -> assert false);
  Printf.printf "PASS large payload roundtrip (%d bytes)\n%!" size
;;

(* ── header_size / max_frame_size constants ───────────────────── *)

let test_constants () =
  assert (Frame.header_size = 9);
  assert (Frame.max_frame_size = 16384);
  Printf.printf "PASS constants\n%!"
;;

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Printf.printf "\n=== H2 Frame Tests (RFC 7540 Section 4) ===\n\n%!";
  test_constants ();
  test_frame_type_roundtrip ();
  test_frame_type_known_values ();
  test_flags ();
  test_parse_header_basic ();
  test_parse_header_stream_id_mask ();
  test_parse_header_too_small ();
  test_write_header ();
  test_parse_complete ();
  test_parse_incomplete_header ();
  test_parse_incomplete_payload ();
  test_parse_with_remaining ();
  test_make_data_end_stream ();
  test_make_data_empty ();
  test_make_headers_flags ();
  test_make_headers_with_priority ();
  test_make_headers_with_priority_weight_bounds ();
  test_priority_roundtrip ();
  test_priority_non_exclusive ();
  test_parse_priority_too_small ();
  test_make_rst_stream ();
  test_rst_stream_roundtrip ();
  test_make_ping ();
  test_ping_roundtrip ();
  test_make_settings ();
  test_make_settings_ack ();
  test_settings_roundtrip ();
  test_make_window_update ();
  test_window_update_stream ();
  test_window_update_roundtrip ();
  test_make_goaway ();
  test_goaway_debug_data ();
  test_goaway_empty_debug ();
  test_goaway_roundtrip ();
  test_make_push_promise ();
  test_make_continuation ();
  test_headers_fragmented_single ();
  test_headers_fragmented_multi ();
  test_headers_fragmented_with_priority ();
  test_push_promise_fragmented_single ();
  test_push_promise_fragmented_multi ();
  test_to_cstruct_size ();
  test_error_codes ();
  test_settings_ids ();
  test_all_frame_types_roundtrip ();
  test_large_payload_roundtrip ();
  Printf.printf "\n=== All H2 Frame tests passed. ===\n%!"
;;
