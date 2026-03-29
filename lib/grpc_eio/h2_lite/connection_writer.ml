(** Connection write path - frame serialization and output.

    Functions in this module handle frame writing, batched I/O,
    priority scheduling, and the echo fast-path. They operate on
    write-side fields: [write_buf], [flow], [closed], [mutex],
    [scheduler], [scheduler_signal]. *)

open Eio.Std

(** Write frame to connection (zero-copy vectored write) *)
let write_frame_direct ~write_buf ~(flow : Eio.Flow.two_way_ty r) ~closed ~mutex
      (frame : Frame.t)
  =
  if Eio.Mutex.use_ro mutex (fun () -> !closed) then failwith "Connection closed";
  (* Build header in write buffer *)
  Frame.write_header write_buf frame.header;
  let header_cs = Cstruct.sub write_buf 0 Frame.header_size in
  (* Vectored write: header + payload (zero-copy) *)
  Eio.Flow.write flow [ header_cs; frame.payload ]
;;

(** Write multiple frames (batch write) - single syscall.

    Concatenate frames into write_buf, then single write.
    For small payloads (gRPC echo), copying to buffer is cheaper
    than multiple small Cstruct allocations and vectored I/O. *)
let write_frames_direct ~write_buf ~(flow : Eio.Flow.two_way_ty r) ~closed ~mutex
      (frames : Frame.t list)
  =
  if Eio.Mutex.use_ro mutex (fun () -> !closed) then failwith "Connection closed";
  (* Calculate total size *)
  let total_size =
    List.fold_left
      (fun acc frame -> acc + Frame.header_size + Cstruct.length frame.Frame.payload)
      0
      frames
  in
  (* Fast path: if total fits in write_buf, copy everything and single write *)
  if total_size <= Cstruct.length write_buf
  then (
    let offset = ref 0 in
    List.iter
      (fun (frame : Frame.t) ->
         (* Write header *)
         Frame.write_header (Cstruct.shift write_buf !offset) frame.Frame.header;
         offset := !offset + Frame.header_size;
         (* Copy payload *)
         let payload_len = Cstruct.length frame.Frame.payload in
         Cstruct.blit frame.Frame.payload 0 write_buf !offset payload_len;
         offset := !offset + payload_len)
      frames;
    (* Single write syscall *)
    Eio.Flow.write flow [ Cstruct.sub write_buf 0 !offset ])
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
    Eio.Flow.write flow iovecs)
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
let start_priority_writer ~sw ~write_buf ~(flow : Eio.Flow.two_way_ty r) ~closed ~mutex
      ~scheduler ~scheduler_signal
  =
  match scheduler, scheduler_signal with
  | Some scheduler, Some signal ->
    Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        match Priority_scheduler.pop_next scheduler with
        | Some frames ->
          write_frames_direct ~write_buf ~flow ~closed ~mutex frames;
          loop ()
        | None ->
          ignore (Eio.Stream.take signal);
          loop ()
      in
      loop ())
  | _ -> ()
;;

(** Write frame with optional priority scheduling *)
let write_frame ~write_buf ~(flow : Eio.Flow.two_way_ty r) ~closed ~mutex ~scheduler
      ~scheduler_signal (frame : Frame.t)
  =
  match scheduler, scheduler_signal with
  | Some scheduler, Some signal when not (is_control_frame frame) ->
    Priority_scheduler.enqueue scheduler ~stream_id:frame.header.stream_id [ frame ];
    Eio.Stream.add signal ()
  | _ -> write_frame_direct ~write_buf ~flow ~closed ~mutex frame
;;

(** Write multiple frames with optional priority scheduling *)
let write_frames ~write_buf ~(flow : Eio.Flow.two_way_ty r) ~closed ~mutex ~scheduler
      ~scheduler_signal (frames : Frame.t list)
  =
  match scheduler, scheduler_signal with
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
          write_frame_direct ~write_buf ~flow ~closed ~mutex frame;
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
  | _ -> write_frames_direct ~write_buf ~flow ~closed ~mutex frames
;;

(** Fast echo response - zero-allocation path for echo benchmarks.

    Writes HEADERS + DATA + TRAILERS in one syscall with minimal allocations.
    Pre-computed templates: only stream_id and message body are patched at runtime.

    Frame layout in write_buf:
    - HEADERS: 9 + 19 = 28 bytes (pre-encoded :status=200, content-type)
    - DATA: 9 + 5 + N bytes (frame header + gRPC header + message)
    - TRAILERS: 9 + 15 = 24 bytes (pre-encoded grpc-status=0) *)
let write_echo_response ~write_buf ~(flow : Eio.Flow.two_way_ty r) ~closed ~mutex
      ~stream_id (message : Cstruct.t)
  =
  if Eio.Mutex.use_ro mutex (fun () -> !closed) then failwith "Connection closed";
  let msg_len = Cstruct.length message in
  let grpc_payload_len = 5 + msg_len in
  (* gRPC header + message *)
  let total_len = 28 + 9 + grpc_payload_len + 24 in
  (* HEADERS + DATA + TRAILERS *)
  if total_len > Cstruct.length write_buf
  then failwith "Message too large for write buffer";
  let buf = write_buf in
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
  Eio.Flow.write flow [ Cstruct.sub buf 0 total_len ]
;;

(** Fast echo response with piggybacked WINDOW_UPDATE - grpc-go optimization.

    Writes HEADERS + DATA + TRAILERS + WINDOW_UPDATE in ONE syscall.
    This eliminates the extra syscall for flow control.

    @param window_increment If > 0, appends connection-level WINDOW_UPDATE *)
let write_echo_response_with_window_update ~write_buf ~(flow : Eio.Flow.two_way_ty r)
      ~closed ~mutex ~stream_id (message : Cstruct.t) ~window_increment
  =
  if Eio.Mutex.use_ro mutex (fun () -> !closed) then failwith "Connection closed";
  let msg_len = Cstruct.length message in
  let grpc_payload_len = 5 + msg_len in
  (* gRPC header + message *)
  let base_len = 28 + 9 + grpc_payload_len + 24 in
  (* HEADERS + DATA + TRAILERS *)
  (* WINDOW_UPDATE: 9 byte header + 4 byte payload = 13 bytes *)
  let window_update_len = if window_increment > 0 then 13 else 0 in
  let total_len = base_len + window_update_len in
  if total_len > Cstruct.length write_buf
  then failwith "Message too large for write buffer";
  let buf = write_buf in
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
  (* Single write syscall - response + window update piggybacked *)
  Eio.Flow.write flow [ Cstruct.sub buf 0 total_len ]
;;
