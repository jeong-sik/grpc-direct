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

(** Re-export Connection_error from connection_common *)
exception Connection_error = Connection_common.Connection_error

(** Re-export header_block type from reader *)
type header_block = Connection_reader.header_block =
  { stream_id : int32
  ; end_stream : bool
  ; header_block : Cstruct.t
  ; priority : Frame.priority_info option
  ; promised_stream_id : int32 option
  }

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

(* ---- Mutable field refs for delegation to reader/writer ---- *)

(** Helper: create refs for closed and read_pos to delegate to reader/writer.
    The reader/writer modules use [ref] parameters to avoid depending on [t]. *)
let with_read_refs t f =
  let read_pos_ref = ref t.read_pos in
  let closed_ref = ref t.closed in
  let last_stream_id_ref = ref t.last_stream_id in
  let result =
    f ~read_pos_ref ~closed_ref ~last_stream_id_ref
  in
  t.read_pos <- !read_pos_ref;
  t.closed <- !closed_ref;
  t.last_stream_id <- !last_stream_id_ref;
  result
;;

let with_write_refs t f =
  let closed_ref = ref t.closed in
  let result = f ~closed_ref in
  t.closed <- !closed_ref;
  result
;;

(* ---- Read path (delegated to Connection_reader) ---- *)

(** Send connection preface (client side) *)
let send_preface t =
  let preface_cs = Cstruct.of_string connection_preface in
  Eio.Flow.write t.flow [ preface_cs ]
;;

(** Receive and validate connection preface (server side) *)
let recv_preface t =
  with_read_refs t (fun ~read_pos_ref ~closed_ref ~last_stream_id_ref:_ ->
    Connection_reader.recv_preface
      ~read_buf:t.read_buf
      ~read_pos:read_pos_ref
      ~flow:t.flow
      ~closed:closed_ref
      ~mutex:t.mutex
      ~connection_preface)
;;

(** Read next frame from connection *)
let read_frame t : Frame.t =
  with_read_refs t (fun ~read_pos_ref ~closed_ref ~last_stream_id_ref ->
    Connection_reader.read_frame
      ~read_buf:t.read_buf
      ~read_pos:read_pos_ref
      ~flow:t.flow
      ~closed:closed_ref
      ~mutex:t.mutex
      ~max_frame_size:t.local_settings.max_frame_size
      ~last_stream_id_ref)
;;

(** Read a complete header block, reassembling CONTINUATION frames if needed. *)
let read_header_block ?first_frame t : header_block =
  (* Build a read_frame function that delegates through the refs *)
  let read_pos_ref = ref t.read_pos in
  let closed_ref = ref t.closed in
  let last_stream_id_ref = ref t.last_stream_id in
  let read_frame_fn () =
    Connection_reader.read_frame
      ~read_buf:t.read_buf
      ~read_pos:read_pos_ref
      ~flow:t.flow
      ~closed:closed_ref
      ~mutex:t.mutex
      ~max_frame_size:t.local_settings.max_frame_size
      ~last_stream_id_ref
  in
  let result =
    Connection_reader.read_header_block ~read_frame_fn ?first_frame ()
  in
  t.read_pos <- !read_pos_ref;
  t.closed <- !closed_ref;
  t.last_stream_id <- !last_stream_id_ref;
  result
;;

(* ---- Write path (delegated to Connection_writer) ---- *)

(** Start priority writer fiber when scheduling is enabled *)
let start_priority_writer ~sw (t : t) =
  let closed_ref = ref t.closed in
  Connection_writer.start_priority_writer
    ~sw
    ~write_buf:t.write_buf
    ~flow:t.flow
    ~closed:closed_ref
    ~mutex:t.mutex
    ~scheduler:t.scheduler
    ~scheduler_signal:t.scheduler_signal;
  t.closed <- !closed_ref
;;

(** Update stream priority for scheduler *)
let update_priority t ~stream_id (priority : Frame.priority_info) =
  match t.scheduler with
  | Some scheduler -> Priority_scheduler.update_priority scheduler ~stream_id priority
  | None -> ()
;;

(** Write frame with optional priority scheduling *)
let write_frame t (frame : Frame.t) =
  with_write_refs t (fun ~closed_ref ->
    Connection_writer.write_frame
      ~write_buf:t.write_buf
      ~flow:t.flow
      ~closed:closed_ref
      ~mutex:t.mutex
      ~scheduler:t.scheduler
      ~scheduler_signal:t.scheduler_signal
      frame)
;;

(** Write multiple frames with optional priority scheduling *)
let write_frames t (frames : Frame.t list) =
  with_write_refs t (fun ~closed_ref ->
    Connection_writer.write_frames
      ~write_buf:t.write_buf
      ~flow:t.flow
      ~closed:closed_ref
      ~mutex:t.mutex
      ~scheduler:t.scheduler
      ~scheduler_signal:t.scheduler_signal
      frames)
;;

(** Fast echo response - zero-allocation path *)
let write_echo_response t ~stream_id (message : Cstruct.t) =
  with_write_refs t (fun ~closed_ref ->
    Connection_writer.write_echo_response
      ~write_buf:t.write_buf
      ~flow:t.flow
      ~closed:closed_ref
      ~mutex:t.mutex
      ~stream_id
      message)
;;

(** Fast echo response with piggybacked WINDOW_UPDATE *)
let write_echo_response_with_window_update
      t
      ~stream_id
      (message : Cstruct.t)
      ~window_increment
  =
  with_write_refs t (fun ~closed_ref ->
    Connection_writer.write_echo_response_with_window_update
      ~write_buf:t.write_buf
      ~flow:t.flow
      ~closed:closed_ref
      ~mutex:t.mutex
      ~stream_id
      message
      ~window_increment)
;;

(* ---- Control frames ---- *)

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
