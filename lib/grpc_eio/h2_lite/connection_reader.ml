(** Connection read path - frame parsing and header block reassembly.

    Functions in this module operate on the read-side fields of a connection:
    [read_buf], [read_pos], [flow], [closed], [mutex], [local_settings],
    [last_stream_id]. They are called by {!Connection} which provides these
    values from the connection record. *)

(** Fill read buffer from network.

    @param read_buf The connection's read buffer (mutable position tracking via ref)
    @param read_pos Current valid bytes in read_buf (ref, updated in place)
    @param flow The Eio two-way flow
    @param closed Ref to check/set closed state
    @param mutex Eio.Mutex protecting shared state *)
let fill_read_buffer ~read_buf ~read_pos ~(flow : Eio.Flow.two_way_ty Eio.Std.r) ~closed
      ~mutex
  =
  if Eio.Mutex.use_ro mutex (fun () -> !closed) then raise End_of_file;
  (* Compact buffer if needed *)
  if !read_pos > 0 && Cstruct.length read_buf - !read_pos < Frame.header_size
  then (
    let valid = Cstruct.sub read_buf 0 !read_pos in
    Cstruct.blit valid 0 read_buf 0 !read_pos);
  (* Read more data *)
  let available = Cstruct.sub read_buf !read_pos (Cstruct.length read_buf - !read_pos) in
  let n = Eio.Flow.single_read flow available in
  if n = 0
  then (
    Eio.Mutex.use_rw ~protect:true mutex (fun () -> closed := true);
    raise End_of_file);
  read_pos := !read_pos + n
;;

(** Read next frame from connection - with payload copy.

    ALWAYS copies payload before shifting remaining data in the read buffer.

    @param max_frame_size Local SETTINGS_MAX_FRAME_SIZE for validation
    @param last_stream_id_ref Updated with the highest stream ID seen *)
let read_frame ~read_buf ~read_pos ~(flow : Eio.Flow.two_way_ty Eio.Std.r) ~closed ~mutex
      ~max_frame_size ~last_stream_id_ref : Frame.t
  =
  let fill () = fill_read_buffer ~read_buf ~read_pos ~flow ~closed ~mutex in
  (* Ensure we have at least a header *)
  while !read_pos < Frame.header_size do
    fill ()
  done;
  (* Parse header to get length *)
  let buf = Cstruct.sub read_buf 0 !read_pos in
  let header, _ = Frame.parse_header buf in
  if header.length > max_frame_size
  then
    raise
      (Connection_common.Connection_error (Frame.Error_code.frame_size_error, "frame too large"));
  (* Ensure we have the full frame *)
  let total_len = Frame.header_size + header.length in
  while !read_pos < total_len do
    fill ()
  done;
  (* Parse complete frame *)
  let buf = Cstruct.sub read_buf 0 !read_pos in
  match Frame.parse buf with
  | None -> failwith "Frame parse failed after ensuring length"
  | Some (frame, remaining) ->
    let remaining_len = Cstruct.length remaining in
    let payload_len = Cstruct.length frame.Frame.payload in
    (* ALWAYS copy payload before shifting remaining data. *)
    let final_payload =
      if payload_len > 0
      then (
        let payload_copy = Cstruct.create payload_len in
        Cstruct.blit frame.Frame.payload 0 payload_copy 0 payload_len;
        payload_copy)
      else frame.Frame.payload
    in
    (* Shift remaining data to front *)
    if remaining_len > 0 then Cstruct.blit remaining 0 read_buf 0 remaining_len;
    read_pos := remaining_len;
    let last =
      if frame.Frame.header.stream_id = 0l
      then !last_stream_id_ref
      else if Int32.compare frame.Frame.header.stream_id !last_stream_id_ref > 0
      then frame.Frame.header.stream_id
      else !last_stream_id_ref
    in
    last_stream_id_ref := last;
    { frame with Frame.payload = final_payload }
;;

(** Parsed header block with optional priority/push metadata *)
type header_block =
  { stream_id : int32
  ; end_stream : bool
  ; header_block : Cstruct.t
  ; priority : Frame.priority_info option
  ; promised_stream_id : int32 option
  }

(** Read a complete header block, reassembling CONTINUATION frames if needed.
    RFC 7540 S6.10: CONTINUATION frames MUST follow HEADERS/PUSH_PROMISE
    until END_HEADERS is received. *)
let read_header_block ~read_frame_fn ?first_frame () : header_block =
  let first_frame =
    match first_frame with
    | Some frame -> frame
    | None -> read_frame_fn ()
  in
  let stream_id = first_frame.Frame.header.stream_id in
  let end_stream = Frame.Flags.is_set first_frame.header.flags Frame.Flags.end_stream in
  (* Check frame type *)
  (match first_frame.header.frame_type with
   | Frame.Headers -> ()
   | Frame.PushPromise ->
     if end_stream then failwith "PUSH_PROMISE must not set END_STREAM"
   | _ -> failwith "Expected HEADERS or PUSH_PROMISE frame");
  let header_fragment_of_headers_frame frame =
    let payload = frame.Frame.payload in
    let payload_len = Cstruct.length payload in
    let off = ref 0 in
    let pad_len =
      if Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.padded
      then (
        if payload_len < 1 then failwith "Invalid HEADERS padding";
        let len = Cstruct.get_uint8 payload 0 in
        off := 1;
        len)
      else 0
    in
    let priority, promised_stream_id =
      match frame.Frame.header.frame_type with
      | Frame.Headers ->
        if Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.priority
        then (
          let prio, off2 = Frame.parse_priority payload ~offset:!off in
          if prio.dependency = stream_id then failwith "PRIORITY dependency on self";
          off := off2;
          Some prio, None)
        else None, None
      | Frame.PushPromise ->
        if payload_len < !off + 4 then failwith "Invalid PUSH_PROMISE payload";
        let promised = Cstruct.BE.get_uint32 payload !off |> Int32.logand 0x7FFFFFFFl in
        if promised = 0l then failwith "Invalid promised stream id 0";
        off := !off + 4;
        None, Some promised
      | _ -> None, None
    in
    let fragment_len = payload_len - !off - pad_len in
    if fragment_len < 0 then failwith "Invalid HEADERS padding length";
    Cstruct.sub payload !off fragment_len, priority, promised_stream_id
  in
  let first_fragment, priority, promised_stream_id =
    header_fragment_of_headers_frame first_frame
  in
  (* Check if END_HEADERS is set - no continuation needed *)
  if Frame.Flags.is_set first_frame.header.flags Frame.Flags.end_headers
  then
    { stream_id; end_stream; header_block = first_fragment; priority; promised_stream_id }
  else (
    (* Need to read CONTINUATION frames until END_HEADERS *)
    let fragments = ref [ first_fragment ] in
    let rec read_continuations () =
      let frame = read_frame_fn () in
      (* Verify same stream ID *)
      if frame.Frame.header.stream_id <> stream_id
      then failwith "CONTINUATION frame on different stream";
      (* Verify frame type *)
      (match frame.header.frame_type with
       | Frame.Continuation -> ()
       | _ -> failwith "Expected CONTINUATION frame");
      fragments := frame.payload :: !fragments;
      (* Check for END_HEADERS *)
      if not (Frame.Flags.is_set frame.header.flags Frame.Flags.end_headers)
      then read_continuations ()
    in
    read_continuations ();
    (* Reassemble fragments *)
    let fragments = List.rev !fragments in
    let total_len = List.fold_left (fun acc cs -> acc + Cstruct.length cs) 0 fragments in
    let result = Cstruct.create total_len in
    let _ =
      List.fold_left
        (fun offset cs ->
           let len = Cstruct.length cs in
           Cstruct.blit cs 0 result offset len;
           offset + len)
        0
        fragments
    in
    { stream_id; end_stream; header_block = result; priority; promised_stream_id })
;;

(** Receive and validate connection preface (server side).

    Reads into read_buf to maintain buffer consistency.
    The connection preface is 24 bytes ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"). *)
let recv_preface ~read_buf ~read_pos ~(flow : Eio.Flow.two_way_ty Eio.Std.r) ~closed
      ~mutex ~connection_preface
  =
  let expected_len = String.length connection_preface in
  (* Read until we have at least the preface length *)
  while !read_pos < expected_len do
    let available = Cstruct.sub read_buf !read_pos (Cstruct.length read_buf - !read_pos) in
    let n = Eio.Flow.single_read flow available in
    if n = 0
    then (
      Eio.Mutex.use_rw ~protect:true mutex (fun () -> closed := true);
      raise End_of_file);
    read_pos := !read_pos + n
  done;
  (* Validate preface from read buffer *)
  let preface_buf = Cstruct.sub read_buf 0 expected_len in
  if Cstruct.to_string preface_buf <> connection_preface
  then failwith "Invalid HTTP/2 connection preface";
  (* Shift remaining data to front of buffer *)
  let remaining_len = !read_pos - expected_len in
  if remaining_len > 0
  then (
    let remaining = Cstruct.sub read_buf expected_len remaining_len in
    Cstruct.blit remaining 0 read_buf 0 remaining_len);
  read_pos := remaining_len
;;
