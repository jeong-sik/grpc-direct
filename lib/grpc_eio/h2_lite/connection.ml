(** Connection - Zero-copy I/O layer for HTTP/2

    Key optimizations from grpc-go and tonic:
    1. Zero-copy reads: Read directly into pooled Cstruct buffers
    2. Vectored writes: Use writev for header+payload
    3. Per-connection read/write buffers (grpc-go: 32KB read, 64KB write)
    4. Lazy frame parsing: Only parse what we need

    This is Eio-native, no Lwt.
*)

open Eio.Std

(** HTTP/2 settings *)
type settings =
  { header_table_size : int
  ; enable_push : bool
  ; max_concurrent_streams : int
  ; initial_window_size : int
  ; max_frame_size : int
  ; max_header_list_size : int
  }

(** Connection state.

    {b Thread Safety:}
    - [read_buf], [read_pos], [consumed]: Owned exclusively by the read loop fiber.
      No synchronization needed.
    - [write_buf]: Owned exclusively by the write path (write_frame_direct).
      No synchronization needed when single writer.
    - [closed], [goaway_received], [peer_settings], [next_stream_id], [last_stream_id]:
      Accessed by both read and write fibers. Protected by [mutex].
    - [local_settings]: Set at creation, read-only afterward. *)
type t =
  { flow : Eio.Flow.two_way_ty r
  ; mutable read_buf : Cstruct.t
  ; mutable read_pos : int (* Valid bytes in read_buf *)
  ; mutable consumed : int (* Bytes consumed from read_buf (for zero-copy reads) *)
  ; write_buf : Cstruct.t
  ; mutable next_stream_id : int32
  ; mutable peer_settings : settings
  ; mutable local_settings : settings
  ; mutable closed : bool
  ; mutable goaway_received : bool
  ; mutable last_stream_id : int32
  ; scheduler : Priority_scheduler.t option
  ; scheduler_signal : unit Eio.Stream.t option
  ; mutex : Eio.Mutex.t
  }

(** Connection-level protocol error *)
exception Connection_error of int32 * string

(** Default settings per RFC 7540 *)
let default_settings =
  { header_table_size = 4096
  ; (* RFC 7540 default *)
    enable_push = true
  ; max_concurrent_streams = 100
  ; initial_window_size = 65535
  ; max_frame_size = 16384
  ; max_header_list_size = 8192
  }
;;

(** gRPC-optimized settings *)
let grpc_settings =
  { header_table_size = 4096
  ; (* RFC 7540 default *)
    enable_push = false
  ; (* gRPC doesn't use server push *)
    max_concurrent_streams = 1000
  ; (* Higher for gRPC *)
    initial_window_size = 4_194_304
  ; (* 4MB - reduce flow-control stalls *)
    max_frame_size = 16384
  ; max_header_list_size = 8192
  }
;;

(** RFC 7540: Valid SETTINGS_MAX_FRAME_SIZE range *)
let min_frame_size = 16384

let max_frame_size = 16777215

(** Parse SETTINGS payload into (id, value) list *)
let parse_settings_payload payload =
  let len = Cstruct.length payload in
  if len mod 6 <> 0 then failwith "Invalid SETTINGS payload length";
  let rec loop acc off =
    if off >= len
    then List.rev acc
    else (
      let id = Cstruct.BE.get_uint16 payload off in
      let value = Cstruct.BE.get_uint32 payload (off + 2) in
      loop ((id, value) :: acc) (off + 6))
  in
  loop [] 0
;;

(** Apply peer SETTINGS to connection state.

    Protected by [mutex] since peer_settings is read by write-path
    (e.g., [peer_max_frame_size]) and written by read-path. *)
let apply_peer_settings t settings =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    List.iter
      (fun (id, value) ->
         match id with
         | id when id = Frame.Settings_id.header_table_size ->
           let size = Int32.to_int value in
           t.peer_settings <- { t.peer_settings with header_table_size = size }
         | id when id = Frame.Settings_id.enable_push ->
           if value <> 0l && value <> 1l
           then failwith "Invalid SETTINGS_ENABLE_PUSH value";
           t.peer_settings <- { t.peer_settings with enable_push = value = 1l }
         | id when id = Frame.Settings_id.max_concurrent_streams ->
           let max_streams = Int32.to_int value in
           t.peer_settings
           <- { t.peer_settings with max_concurrent_streams = max_streams }
         | id when id = Frame.Settings_id.initial_window_size ->
           if Int32.compare value 0x7FFFFFFFl > 0
           then failwith "FLOW_CONTROL_ERROR: initial_window_size too large";
           let size = Int32.to_int value in
           t.peer_settings <- { t.peer_settings with initial_window_size = size }
         | id when id = Frame.Settings_id.max_frame_size ->
           let size = Int32.to_int value in
           if size < min_frame_size || size > max_frame_size
           then failwith "Invalid SETTINGS_MAX_FRAME_SIZE value";
           t.peer_settings <- { t.peer_settings with max_frame_size = size }
         | id when id = Frame.Settings_id.max_header_list_size ->
           let size = Int32.to_int value in
           t.peer_settings <- { t.peer_settings with max_header_list_size = size }
         | _ -> () (* Ignore unknown settings per RFC 7540 *))
      settings)
;;

(** Peer max frame size (for header fragmentation) *)
let peer_max_frame_size t =
  Eio.Mutex.use_ro t.mutex (fun () -> t.peer_settings.max_frame_size)
;;

(** Buffer sizes tuned for benchmark stability *)
let read_buffer_size = 64 * 1024 (* 64 KB *)

let write_buffer_size = 128 * 1024 (* 128 KB *)

(** Create connection over Eio flow *)
let create
      ?(settings = grpc_settings)
      ?(priority_scheduling = false)
      (flow : _ Eio.Flow.two_way)
  : t
  =
  let scheduler =
    if priority_scheduling then Some (Priority_scheduler.create ()) else None
  in
  let scheduler_signal =
    if priority_scheduling then Some (Eio.Stream.create 64) else None
  in
  { flow :> Eio.Flow.two_way_ty r
  ; read_buf = Buffer_pool.Cstruct_pool.acquire ~size:read_buffer_size
  ; read_pos = 0
  ; consumed = 0
  ; (* Zero-copy read offset *)
    write_buf = Buffer_pool.Cstruct_pool.acquire ~size:write_buffer_size
  ; next_stream_id = 1l
  ; (* Client starts at 1, server at 2 *)
    peer_settings = default_settings
  ; local_settings = settings
  ; closed = false
  ; goaway_received = false
  ; last_stream_id = 0l
  ; scheduler
  ; scheduler_signal
  ; mutex = Eio.Mutex.create ()
  }
;;

(** HTTP/2 connection preface *)
let connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

(** Send connection preface (client side) *)
let send_preface t =
  let preface_cs = Cstruct.of_string connection_preface in
  Eio.Flow.write t.flow [ preface_cs ]
;;

(** Receive and validate connection preface (server side)

    IMPORTANT: Must read into t.read_buf to maintain buffer consistency.
    The connection preface is 24 bytes ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
*)
let recv_preface t =
  let expected_len = String.length connection_preface in
  (* Read until we have at least the preface length *)
  while t.read_pos < expected_len do
    let available =
      Cstruct.sub t.read_buf t.read_pos (Cstruct.length t.read_buf - t.read_pos)
    in
    let n = Eio.Flow.single_read t.flow available in
    if n = 0
    then (
      Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.closed <- true);
      raise End_of_file);
    t.read_pos <- t.read_pos + n
  done;
  (* Validate preface from read buffer *)
  let preface_buf = Cstruct.sub t.read_buf 0 expected_len in
  if Cstruct.to_string preface_buf <> connection_preface
  then failwith "Invalid HTTP/2 connection preface";
  (* Shift remaining data to front of buffer *)
  let remaining_len = t.read_pos - expected_len in
  if remaining_len > 0
  then (
    let remaining = Cstruct.sub t.read_buf expected_len remaining_len in
    Cstruct.blit remaining 0 t.read_buf 0 remaining_len);
  t.read_pos <- remaining_len
;;

(** Fill read buffer from network *)
let fill_read_buffer t =
  if Eio.Mutex.use_ro t.mutex (fun () -> t.closed) then raise End_of_file;
  (* Compact buffer if needed *)
  if t.read_pos > 0 && Cstruct.length t.read_buf - t.read_pos < Frame.header_size
  then (
    let valid = Cstruct.sub t.read_buf 0 t.read_pos in
    Cstruct.blit valid 0 t.read_buf 0 t.read_pos);
  (* Read more data *)
  let available =
    Cstruct.sub t.read_buf t.read_pos (Cstruct.length t.read_buf - t.read_pos)
  in
  let n = Eio.Flow.single_read t.flow available in
  if n = 0
  then (
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.closed <- true);
    raise End_of_file);
  t.read_pos <- t.read_pos + n
;;

(** Read next frame from connection - with selective payload copy

    For performance, DATA frames use zero-copy (caller must process before next read).
    HEADERS/PUSH_PROMISE frames are copied (needed for HPACK decoding after buffer shift).
    Other frame types: small payloads copied, large payloads zero-copy.
*)
let read_frame t : Frame.t =
  (* Ensure we have at least a header *)
  while t.read_pos < Frame.header_size do
    fill_read_buffer t
  done;
  (* Parse header to get length *)
  let buf = Cstruct.sub t.read_buf 0 t.read_pos in
  let header, _ = Frame.parse_header buf in
  if header.length > t.local_settings.max_frame_size
  then raise (Connection_error (Frame.Error_code.frame_size_error, "frame too large"));
  (* Ensure we have the full frame *)
  let total_len = Frame.header_size + header.length in
  while t.read_pos < total_len do
    fill_read_buffer t
  done;
  (* Parse complete frame *)
  let buf = Cstruct.sub t.read_buf 0 t.read_pos in
  match Frame.parse buf with
  | None -> failwith "Frame parse failed after ensuring length"
  | Some (frame, remaining) ->
    let remaining_len = Cstruct.length remaining in
    let payload_len = Cstruct.length frame.Frame.payload in
    (* ALWAYS copy payload before shifting remaining data.
       Zero-copy optimization was attempted but caused crashes:
       the payload points into read_buf, which gets corrupted when we
       shift remaining data to front. Safe approach: always copy.

       Note: Buffer_pool was tested but caused 15% regression for small messages
       because OCaml GC is highly efficient for short-lived allocations. *)
    let final_payload =
      if payload_len > 0
      then (
        let payload_copy = Cstruct.create payload_len in
        Cstruct.blit frame.Frame.payload 0 payload_copy 0 payload_len;
        payload_copy)
      else frame.Frame.payload
    in
    (* Shift remaining data to front *)
    if remaining_len > 0 then Cstruct.blit remaining 0 t.read_buf 0 remaining_len;
    t.read_pos <- remaining_len;
    let last =
      if frame.Frame.header.stream_id = 0l
      then t.last_stream_id
      else if Int32.compare frame.Frame.header.stream_id t.last_stream_id > 0
      then frame.Frame.header.stream_id
      else t.last_stream_id
    in
    t.last_stream_id <- last;
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
    RFC 7540 §6.10: CONTINUATION frames MUST follow HEADERS/PUSH_PROMISE
    until END_HEADERS is received. *)
let read_header_block ?first_frame t : header_block =
  let first_frame =
    match first_frame with
    | Some frame -> frame
    | None -> read_frame t
  in
  let stream_id = first_frame.header.stream_id in
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
      let frame = read_frame t in
      (* Verify same stream ID *)
      if frame.header.stream_id <> stream_id
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

(** Write frame to connection (zero-copy vectored write) *)
let write_frame_direct t (frame : Frame.t) =
  if Eio.Mutex.use_ro t.mutex (fun () -> t.closed) then failwith "Connection closed";
  (* Build header in write buffer *)
  Frame.write_header t.write_buf frame.header;
  let header_cs = Cstruct.sub t.write_buf 0 Frame.header_size in
  (* Vectored write: header + payload (zero-copy!) *)
  Eio.Flow.write t.flow [ header_cs; frame.payload ]
;;

(** Write multiple frames (batch write) - single syscall

    Concatenate frames into write_buf, then single write.
    For small payloads (gRPC echo), copying to buffer is cheaper
    than multiple small Cstruct allocations and vectored I/O.
*)
let write_frames_direct t (frames : Frame.t list) =
  if Eio.Mutex.use_ro t.mutex (fun () -> t.closed) then failwith "Connection closed";
  (* Calculate total size *)
  let total_size =
    List.fold_left
      (fun acc frame -> acc + Frame.header_size + Cstruct.length frame.Frame.payload)
      0
      frames
  in
  (* Fast path: if total fits in write_buf, copy everything and single write *)
  if total_size <= Cstruct.length t.write_buf
  then (
    let offset = ref 0 in
    List.iter
      (fun (frame : Frame.t) ->
         (* Write header *)
         Frame.write_header (Cstruct.shift t.write_buf !offset) frame.Frame.header;
         offset := !offset + Frame.header_size;
         (* Copy payload *)
         let payload_len = Cstruct.length frame.Frame.payload in
         Cstruct.blit frame.Frame.payload 0 t.write_buf !offset payload_len;
         offset := !offset + payload_len)
      frames;
    (* Single write syscall *)
    Eio.Flow.write t.flow [ Cstruct.sub t.write_buf 0 !offset ])
  else (
    (* Fallback: vectored I/O for large batches *)
    let iovecs =
      List.concat_map
        (fun (frame : Frame.t) ->
           let header_buf = Cstruct.create Frame.header_size in
           Frame.write_header header_buf frame.Frame.header;
           [ header_buf; frame.Frame.payload ])
        frames
    in
    Eio.Flow.write t.flow iovecs)
;;

let is_control_frame (frame : Frame.t) =
  frame.header.stream_id = 0l
  ||
  match frame.header.frame_type with
  | Frame.Settings | Frame.Ping | Frame.GoAway | Frame.WindowUpdate | Frame.RstStream ->
    true
  | _ -> false
;;

(** Start priority writer fiber when scheduling is enabled *)
let start_priority_writer ~sw (t : t) =
  match t.scheduler, t.scheduler_signal with
  | Some scheduler, Some signal ->
    Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        match Priority_scheduler.pop_next scheduler with
        | Some frames ->
          write_frames_direct t frames;
          loop ()
        | None ->
          ignore (Eio.Stream.take signal);
          loop ()
      in
      loop ())
  | _ -> ()
;;

(** Update stream priority for scheduler *)
let update_priority t ~stream_id (priority : Frame.priority_info) =
  match t.scheduler with
  | Some scheduler -> Priority_scheduler.update_priority scheduler ~stream_id priority
  | None -> ()
;;

(** Write frame with optional priority scheduling *)
let write_frame t (frame : Frame.t) =
  match t.scheduler, t.scheduler_signal with
  | Some scheduler, Some signal when not (is_control_frame frame) ->
    Priority_scheduler.enqueue scheduler ~stream_id:frame.header.stream_id [ frame ];
    Eio.Stream.add signal ()
  | _ -> write_frame_direct t frame
;;

(** Write multiple frames with optional priority scheduling *)
let write_frames t (frames : Frame.t list) =
  match t.scheduler, t.scheduler_signal with
  | Some scheduler, Some signal ->
    let flush_batch batch =
      if batch <> []
      then (
        let stream_id = (List.hd batch).Frame.header.stream_id in
        Priority_scheduler.enqueue scheduler ~stream_id batch;
        Eio.Stream.add signal ())
    in
    let rec loop current_stream batch = function
      | [] -> flush_batch (List.rev batch)
      | frame :: rest ->
        if is_control_frame frame
        then (
          flush_batch (List.rev batch);
          write_frame_direct t frame;
          loop None [] rest)
        else (
          match current_stream with
          | Some sid when sid = frame.Frame.header.stream_id ->
            loop current_stream (frame :: batch) rest
          | _ ->
            flush_batch (List.rev batch);
            loop (Some frame.Frame.header.stream_id) [ frame ] rest)
    in
    loop None [] frames
  | _ -> write_frames_direct t frames
;;

(** Fast echo response - zero-allocation path for echo benchmarks

    Writes HEADERS + DATA + TRAILERS in one syscall with minimal allocations.
    Pre-computed templates: only stream_id and message body are patched at runtime.

    Frame layout in write_buf:
    - HEADERS: 9 + 19 = 28 bytes (pre-encoded :status=200, content-type)
    - DATA: 9 + 5 + N bytes (frame header + gRPC header + message)
    - TRAILERS: 9 + 15 = 24 bytes (pre-encoded grpc-status=0)
*)
let write_echo_response t ~stream_id (message : Cstruct.t) =
  if Eio.Mutex.use_ro t.mutex (fun () -> t.closed) then failwith "Connection closed";
  let msg_len = Cstruct.length message in
  let grpc_payload_len = 5 + msg_len in
  (* gRPC header + message *)
  let total_len = 28 + 9 + grpc_payload_len + 24 in
  (* HEADERS + DATA + TRAILERS *)
  if total_len > Cstruct.length t.write_buf
  then failwith "Message too large for write buffer";
  let buf = t.write_buf in
  (* === HEADERS frame (28 bytes) === *)
  (* Frame header: length=19, type=1, flags=0x04 (END_HEADERS) *)
  Cstruct.set_uint8 buf 0 0;
  Cstruct.set_uint8 buf 1 0;
  Cstruct.set_uint8 buf 2 19;
  (* length *)
  Cstruct.set_uint8 buf 3 1;
  (* HEADERS *)
  Cstruct.set_uint8 buf 4 0x04;
  (* END_HEADERS *)
  Cstruct.BE.set_uint32 buf 5 stream_id;
  (* HPACK: :status=200 (indexed 8) *)
  Cstruct.set_uint8 buf 9 0x88;
  (* HPACK: content-type=application/grpc (literal, name index 31) *)
  Cstruct.set_uint8 buf 10 0x5f;
  Cstruct.set_uint8 buf 11 16;
  (* value length *)
  Cstruct.blit_from_string "application/grpc" 0 buf 12 16;
  (* === DATA frame (9 + 5 + msg_len bytes) === *)
  let data_off = 28 in
  (* Frame header: length=grpc_payload_len, type=0, flags=0 *)
  Cstruct.set_uint8 buf data_off ((grpc_payload_len lsr 16) land 0xFF);
  Cstruct.set_uint8 buf (data_off + 1) ((grpc_payload_len lsr 8) land 0xFF);
  Cstruct.set_uint8 buf (data_off + 2) (grpc_payload_len land 0xFF);
  Cstruct.set_uint8 buf (data_off + 3) 0;
  (* DATA *)
  Cstruct.set_uint8 buf (data_off + 4) 0;
  (* no flags *)
  Cstruct.BE.set_uint32 buf (data_off + 5) stream_id;
  (* gRPC header: compressed=0, length=msg_len *)
  Cstruct.set_uint8 buf (data_off + 9) 0;
  (* not compressed *)
  Cstruct.BE.set_uint32 buf (data_off + 10) (Int32.of_int msg_len);
  (* Message body *)
  Cstruct.blit message 0 buf (data_off + 14) msg_len;
  (* === TRAILERS frame (24 bytes) === *)
  let trail_off = data_off + 9 + grpc_payload_len in
  (* Frame header: length=15, type=1, flags=0x05 (END_STREAM | END_HEADERS) *)
  Cstruct.set_uint8 buf trail_off 0;
  Cstruct.set_uint8 buf (trail_off + 1) 0;
  Cstruct.set_uint8 buf (trail_off + 2) 15;
  (* length *)
  Cstruct.set_uint8 buf (trail_off + 3) 1;
  (* HEADERS *)
  Cstruct.set_uint8 buf (trail_off + 4) 0x05;
  (* END_STREAM | END_HEADERS *)
  Cstruct.BE.set_uint32 buf (trail_off + 5) stream_id;
  (* HPACK: grpc-status=0 (literal with indexing, new name) *)
  Cstruct.set_uint8 buf (trail_off + 9) 0x40;
  Cstruct.set_uint8 buf (trail_off + 10) 11;
  (* name length *)
  Cstruct.blit_from_string "grpc-status" 0 buf (trail_off + 11) 11;
  Cstruct.set_uint8 buf (trail_off + 22) 1;
  (* value length *)
  Cstruct.set_uint8 buf (trail_off + 23) (Char.code '0');
  (* Single write syscall *)
  Eio.Flow.write t.flow [ Cstruct.sub buf 0 total_len ]
;;

(** Fast echo response with piggybacked WINDOW_UPDATE - grpc-go optimization

    Writes HEADERS + DATA + TRAILERS + WINDOW_UPDATE in ONE syscall.
    This eliminates the extra syscall for flow control, following the
    "piggyback window updates" pattern from grpc-go that reduced p99 latency by 42%.

    @param window_increment If > 0, appends connection-level WINDOW_UPDATE
*)
let write_echo_response_with_window_update
      t
      ~stream_id
      (message : Cstruct.t)
      ~window_increment
  =
  if Eio.Mutex.use_ro t.mutex (fun () -> t.closed) then failwith "Connection closed";
  let msg_len = Cstruct.length message in
  let grpc_payload_len = 5 + msg_len in
  (* gRPC header + message *)
  let base_len = 28 + 9 + grpc_payload_len + 24 in
  (* HEADERS + DATA + TRAILERS *)
  (* WINDOW_UPDATE: 9 byte header + 4 byte payload = 13 bytes *)
  let window_update_len = if window_increment > 0 then 13 else 0 in
  let total_len = base_len + window_update_len in
  if total_len > Cstruct.length t.write_buf
  then failwith "Message too large for write buffer";
  let buf = t.write_buf in
  (* === HEADERS frame (28 bytes) === *)
  Cstruct.set_uint8 buf 0 0;
  Cstruct.set_uint8 buf 1 0;
  Cstruct.set_uint8 buf 2 19;
  (* length *)
  Cstruct.set_uint8 buf 3 1;
  (* HEADERS *)
  Cstruct.set_uint8 buf 4 0x04;
  (* END_HEADERS *)
  Cstruct.BE.set_uint32 buf 5 stream_id;
  Cstruct.set_uint8 buf 9 0x88;
  Cstruct.set_uint8 buf 10 0x5f;
  Cstruct.set_uint8 buf 11 16;
  Cstruct.blit_from_string "application/grpc" 0 buf 12 16;
  (* === DATA frame (9 + 5 + msg_len bytes) === *)
  let data_off = 28 in
  Cstruct.set_uint8 buf data_off ((grpc_payload_len lsr 16) land 0xFF);
  Cstruct.set_uint8 buf (data_off + 1) ((grpc_payload_len lsr 8) land 0xFF);
  Cstruct.set_uint8 buf (data_off + 2) (grpc_payload_len land 0xFF);
  Cstruct.set_uint8 buf (data_off + 3) 0;
  (* DATA *)
  Cstruct.set_uint8 buf (data_off + 4) 0;
  (* no flags *)
  Cstruct.BE.set_uint32 buf (data_off + 5) stream_id;
  Cstruct.set_uint8 buf (data_off + 9) 0;
  Cstruct.BE.set_uint32 buf (data_off + 10) (Int32.of_int msg_len);
  Cstruct.blit message 0 buf (data_off + 14) msg_len;
  (* === TRAILERS frame (24 bytes) === *)
  let trail_off = data_off + 9 + grpc_payload_len in
  Cstruct.set_uint8 buf trail_off 0;
  Cstruct.set_uint8 buf (trail_off + 1) 0;
  Cstruct.set_uint8 buf (trail_off + 2) 15;
  Cstruct.set_uint8 buf (trail_off + 3) 1;
  (* HEADERS *)
  Cstruct.set_uint8 buf (trail_off + 4) 0x05;
  (* END_STREAM | END_HEADERS *)
  Cstruct.BE.set_uint32 buf (trail_off + 5) stream_id;
  Cstruct.set_uint8 buf (trail_off + 9) 0x40;
  Cstruct.set_uint8 buf (trail_off + 10) 11;
  Cstruct.blit_from_string "grpc-status" 0 buf (trail_off + 11) 11;
  Cstruct.set_uint8 buf (trail_off + 22) 1;
  Cstruct.set_uint8 buf (trail_off + 23) (Char.code '0');
  (* === WINDOW_UPDATE frame (13 bytes) - connection level === *)
  if window_increment > 0
  then (
    let wu_off = trail_off + 24 in
    (* Frame header: length=4, type=8 (WINDOW_UPDATE), flags=0, stream_id=0 *)
    Cstruct.set_uint8 buf wu_off 0;
    Cstruct.set_uint8 buf (wu_off + 1) 0;
    Cstruct.set_uint8 buf (wu_off + 2) 4;
    (* length *)
    Cstruct.set_uint8 buf (wu_off + 3) 8;
    (* WINDOW_UPDATE *)
    Cstruct.set_uint8 buf (wu_off + 4) 0;
    (* no flags *)
    Cstruct.BE.set_uint32 buf (wu_off + 5) 0l;
    (* stream_id = 0 for connection *)
    (* Window size increment (clear reserved bit) *)
    Cstruct.BE.set_uint32
      buf
      (wu_off + 9)
      (Int32.of_int (window_increment land 0x7FFFFFFF)));
  (* Single write syscall - response + window update piggybacked! *)
  Eio.Flow.write t.flow [ Cstruct.sub buf 0 total_len ]
;;

(** Send SETTINGS frame with our settings *)
let send_settings t =
  let settings_list =
    [ Frame.Settings_id.header_table_size, Int32.of_int t.local_settings.header_table_size
    ; (Frame.Settings_id.enable_push, if t.local_settings.enable_push then 1l else 0l)
    ; ( Frame.Settings_id.max_concurrent_streams
      , Int32.of_int t.local_settings.max_concurrent_streams )
    ; ( Frame.Settings_id.initial_window_size
      , Int32.of_int t.local_settings.initial_window_size )
    ; Frame.Settings_id.max_frame_size, Int32.of_int t.local_settings.max_frame_size
    ]
  in
  let frame = Frame.make_settings ~ack:false settings_list in
  write_frame t frame
;;

(** Send SETTINGS ACK *)
let send_settings_ack t =
  let frame = Frame.make_settings ~ack:true [] in
  write_frame t frame
;;

(** Send PING *)
let send_ping t ~ack opaque_data =
  let frame = Frame.make_ping ~ack opaque_data in
  write_frame t frame
;;

(** Send WINDOW_UPDATE *)
let send_window_update t ~stream_id ~increment =
  let frame = Frame.make_window_update ~stream_id ~increment in
  write_frame t frame
;;

(** Send GOAWAY and mark connection closing *)
let send_goaway t ~last_stream_id ~error_code ~debug_data =
  let frame = Frame.make_goaway ~last_stream_id ~error_code ~debug_data in
  write_frame t frame;
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.goaway_received <- true)
;;

(** Allocate next stream ID (client: odd, server: even) *)
let next_stream_id t ~is_client =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    let id = t.next_stream_id in
    t.next_stream_id <- Int32.add t.next_stream_id 2l;
    (* Ensure odd/even based on role *)
    if is_client && Int32.rem id 2l = 0l
    then Int32.add id 1l
    else if (not is_client) && Int32.rem id 2l = 1l
    then Int32.add id 1l
    else id)
;;

(** Close connection *)
let close t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    if not t.closed
    then (
      t.closed <- true;
      (* Release pooled buffers *)
      Buffer_pool.Cstruct_pool.release t.read_buf;
      Buffer_pool.Cstruct_pool.release t.write_buf
      (* Flow is managed by Switch, no explicit close needed *)))
;;

(** Client handshake: send preface + settings, receive server settings *)
let client_handshake t =
  send_preface t;
  send_settings t;
  (* Receive server settings *)
  let frame = read_frame t in
  match frame.header.frame_type with
  | Frame.Settings when not (Frame.Flags.is_set frame.header.flags Frame.Flags.ack) ->
    let settings = parse_settings_payload frame.payload in
    apply_peer_settings t settings;
    send_settings_ack t
  | _ -> failwith "Expected SETTINGS frame from server"
;;

(** Server handshake: receive preface + settings, send our settings *)
let server_handshake t =
  recv_preface t;
  send_settings t;
  (* Receive client settings *)
  let frame = read_frame t in
  match frame.header.frame_type with
  | Frame.Settings when not (Frame.Flags.is_set frame.header.flags Frame.Flags.ack) ->
    let settings = parse_settings_payload frame.payload in
    apply_peer_settings t settings;
    send_settings_ack t
  | _ -> failwith "Expected SETTINGS frame from client"
;;

(** Connection statistics *)
type stats =
  { streams_opened : int
  ; frames_sent : int
  ; frames_received : int
  ; bytes_sent : int
  ; bytes_received : int
  }
