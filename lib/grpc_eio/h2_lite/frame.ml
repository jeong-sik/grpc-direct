(** HTTP/2 Frame Parser - gRPC-specific minimal implementation

    Full HTTP/2 has 10 frame types. gRPC uses a subset, but we implement:
    - HEADERS (0x1): Request/response headers (with optional priority)
    - DATA (0x0): Message payload
    - RST_STREAM (0x3): Stream cancellation
    - PING (0x6): Keep-alive
    - PRIORITY (0x2) and PUSH_PROMISE (0x5) for full RFC support

    Reference: RFC 7540 Section 4.1 (Frame Format)
    +-----------------------------------------------+
    |                 Length (24)                   |
    +---------------+---------------+---------------+
    |   Type (8)    |   Flags (8)   |
    +-+-------------+---------------+-------------------------------+
    |R|                 Stream Identifier (31)                      |
    +=+=============================================================+
    |                   Frame Payload (0...)                      ...
    +---------------------------------------------------------------+
*)

(** Frame types per RFC 7540 §6 *)
type frame_type =
  | Data         (* 0x0 *)
  | Headers      (* 0x1 *)
  | Priority     (* 0x2 *)
  | RstStream    (* 0x3 *)
  | Settings     (* 0x4 *)
  | PushPromise  (* 0x5 - not used by gRPC *)
  | Ping         (* 0x6 *)
  | GoAway       (* 0x7 *)
  | WindowUpdate (* 0x8 *)
  | Continuation (* 0x9 - for large headers *)
  | Unknown of int

(** HTTP/2 priority info (RFC 7540 §5.3) *)
type priority_info = {
  exclusive : bool;
  dependency : int32;  (* Stream ID, 0 = root *)
  weight : int;        (* 1-256 *)
}

let frame_type_of_int = function
  | 0 -> Data
  | 1 -> Headers
  | 2 -> Priority
  | 3 -> RstStream
  | 4 -> Settings
  | 5 -> PushPromise
  | 6 -> Ping
  | 7 -> GoAway
  | 8 -> WindowUpdate
  | 9 -> Continuation
  | n -> Unknown n

let int_of_frame_type = function
  | Data -> 0
  | Headers -> 1
  | Priority -> 2
  | RstStream -> 3
  | Settings -> 4
  | PushPromise -> 5
  | Ping -> 6
  | GoAway -> 7
  | WindowUpdate -> 8
  | Continuation -> 9
  | Unknown n -> n

(** Frame flags *)
module Flags = struct
  let end_stream = 0x1
  let end_headers = 0x4
  let padded = 0x8
  let priority = 0x20
  let ack = 0x1  (* For SETTINGS and PING *)

  let is_set flags flag = flags land flag <> 0
end

(** Parsed frame header (9 bytes) *)
type header = {
  length : int;       (* 24 bits, max 16384 for gRPC *)
  frame_type : frame_type;
  flags : int;
  stream_id : int32;  (* 31 bits, high bit always 0 *)
}

(** Complete frame with payload *)
type t = {
  header : header;
  payload : Cstruct.t;
}

(** Frame header size is always 9 bytes *)
let header_size = 9

(** Max frame size for gRPC (default, can be negotiated higher) *)
let max_frame_size = 16384

(** Parse frame header from buffer (zero-copy)

    Returns header and remaining buffer after header.
    Raises Invalid_argument if buffer too small.
*)
let parse_header (buf : Cstruct.t) : header * Cstruct.t =
  if Cstruct.length buf < header_size then
    invalid_arg "Buffer too small for frame header";

  (* Length: 24 bits big-endian *)
  let length =
    (Cstruct.get_uint8 buf 0 lsl 16) lor
    (Cstruct.get_uint8 buf 1 lsl 8) lor
    (Cstruct.get_uint8 buf 2)
  in

  let frame_type = frame_type_of_int (Cstruct.get_uint8 buf 3) in
  let flags = Cstruct.get_uint8 buf 4 in

  (* Stream ID: 32 bits, but high bit is reserved (always 0) *)
  let stream_id = Cstruct.BE.get_uint32 buf 5 in
  let stream_id = Int32.logand stream_id 0x7FFFFFFFl in

  let remaining = Cstruct.shift buf header_size in
  ({ length; frame_type; flags; stream_id }, remaining)

(** Parse complete frame from buffer (zero-copy)

    Returns frame and remaining buffer after frame.
    Returns None if buffer doesn't contain complete frame.
*)
let parse (buf : Cstruct.t) : (t * Cstruct.t) option =
  if Cstruct.length buf < header_size then
    None
  else
    let header, rest = parse_header buf in
    if Cstruct.length rest < header.length then
      None
    else
      let payload = Cstruct.sub rest 0 header.length in
      let remaining = Cstruct.shift rest header.length in
      Some ({ header; payload }, remaining)

(** Write frame header to buffer (zero-copy)

    Caller must ensure buf has at least 9 bytes.
*)
let write_header (buf : Cstruct.t) (h : header) : unit =
  (* Length: 24 bits big-endian *)
  Cstruct.set_uint8 buf 0 ((h.length lsr 16) land 0xFF);
  Cstruct.set_uint8 buf 1 ((h.length lsr 8) land 0xFF);
  Cstruct.set_uint8 buf 2 (h.length land 0xFF);

  Cstruct.set_uint8 buf 3 (int_of_frame_type h.frame_type);
  Cstruct.set_uint8 buf 4 h.flags;
  Cstruct.BE.set_uint32 buf 5 h.stream_id

(** Create DATA frame for gRPC message *)
let make_data ~stream_id ~end_stream (payload : Cstruct.t) : t =
  let flags = if end_stream then Flags.end_stream else 0 in
  {
    header = {
      length = Cstruct.length payload;
      frame_type = Data;
      flags;
      stream_id;
    };
    payload;
  }

(** Create HEADERS frame for gRPC

    Note: HPACK encoding is done separately.
    This just wraps encoded headers in a frame.
*)
let make_headers ~stream_id ~end_stream ~end_headers (payload : Cstruct.t) : t =
  let flags =
    (if end_stream then Flags.end_stream else 0) lor
    (if end_headers then Flags.end_headers else 0)
  in
  {
    header = {
      length = Cstruct.length payload;
      frame_type = Headers;
      flags;
      stream_id;
    };
    payload;
  }

(** Create HEADERS frame with priority info (RFC 7540 §5.3.1) *)
let make_headers_with_priority ~stream_id ~end_stream ~end_headers
    ~(priority : priority_info) (payload : Cstruct.t) : t =
  if priority.weight < 1 || priority.weight > 256 then
    invalid_arg "Priority weight out of range (1-256)";
  let priority_payload = Cstruct.create 5 in
  let dep = Int32.logand priority.dependency 0x7FFFFFFFl in
  let dep = if priority.exclusive then Int32.logor dep 0x80000000l else dep in
  Cstruct.BE.set_uint32 priority_payload 0 dep;
  Cstruct.set_uint8 priority_payload 4 (priority.weight - 1);
  let total_len = 5 + Cstruct.length payload in
  let combined = Cstruct.create total_len in
  Cstruct.blit priority_payload 0 combined 0 5;
  Cstruct.blit payload 0 combined 5 (Cstruct.length payload);
  let flags =
    Flags.priority lor
    (if end_stream then Flags.end_stream else 0) lor
    (if end_headers then Flags.end_headers else 0)
  in
  {
    header = {
      length = total_len;
      frame_type = Headers;
      flags;
      stream_id;
    };
    payload = combined;
  }

(** Create PRIORITY frame (RFC 7540 §6.3) *)
let make_priority ~stream_id (priority : priority_info) : t =
  if priority.weight < 1 || priority.weight > 256 then
    invalid_arg "Priority weight out of range (1-256)";
  let payload = Cstruct.create 5 in
  let dep = Int32.logand priority.dependency 0x7FFFFFFFl in
  let dep = if priority.exclusive then Int32.logor dep 0x80000000l else dep in
  Cstruct.BE.set_uint32 payload 0 dep;
  Cstruct.set_uint8 payload 4 (priority.weight - 1);
  {
    header = {
      length = 5;
      frame_type = Priority;
      flags = 0;
      stream_id;
    };
    payload;
  }

(** Parse priority fields from payload (RFC 7540 §6.3) *)
let parse_priority (payload : Cstruct.t) ~offset : priority_info * int =
  if Cstruct.length payload < offset + 5 then
    invalid_arg "PRIORITY payload too small";
  let raw = Cstruct.BE.get_uint32 payload offset in
  let exclusive = Int32.logand raw 0x80000000l <> 0l in
  let dependency = Int32.logand raw 0x7FFFFFFFl in
  let weight = Cstruct.get_uint8 payload (offset + 4) + 1 in
  ({ exclusive; dependency; weight }, offset + 5)

(** Create PUSH_PROMISE frame (RFC 7540 §6.6) *)
let make_push_promise ~stream_id ~promised_stream_id ~end_headers
    (payload : Cstruct.t) : t =
  let promised = Int32.logand promised_stream_id 0x7FFFFFFFl in
  let total_len = 4 + Cstruct.length payload in
  let combined = Cstruct.create total_len in
  Cstruct.BE.set_uint32 combined 0 promised;
  Cstruct.blit payload 0 combined 4 (Cstruct.length payload);
  {
    header = {
      length = total_len;
      frame_type = PushPromise;
      flags = if end_headers then Flags.end_headers else 0;
      stream_id;
    };
    payload = combined;
  }

(** Create RST_STREAM frame *)
let make_rst_stream ~stream_id ~error_code : t =
  let payload = Cstruct.create 4 in
  Cstruct.BE.set_uint32 payload 0 error_code;
  {
    header = {
      length = 4;
      frame_type = RstStream;
      flags = 0;
      stream_id;
    };
    payload;
  }

(** Create PING frame *)
let make_ping ~ack (opaque_data : Cstruct.t) : t =
  assert (Cstruct.length opaque_data = 8);
  {
    header = {
      length = 8;
      frame_type = Ping;
      flags = if ack then Flags.ack else 0;
      stream_id = 0l;
    };
    payload = opaque_data;
  }

(** Create SETTINGS frame *)
let make_settings ~ack (settings : (int * int32) list) : t =
  let payload_len = List.length settings * 6 in
  let payload = Cstruct.create payload_len in
  List.iteri (fun i (id, value) ->
    let offset = i * 6 in
    Cstruct.BE.set_uint16 payload offset id;
    Cstruct.BE.set_uint32 payload (offset + 2) value
  ) settings;
  {
    header = {
      length = payload_len;
      frame_type = Settings;
      flags = if ack then Flags.ack else 0;
      stream_id = 0l;
    };
    payload;
  }

(** Create WINDOW_UPDATE frame *)
let make_window_update ~stream_id ~increment : t =
  let payload = Cstruct.create 4 in
  Cstruct.BE.set_uint32 payload 0 (Int32.logand increment 0x7FFFFFFFl);
  {
    header = {
      length = 4;
      frame_type = WindowUpdate;
      flags = 0;
      stream_id;
    };
    payload;
  }

(** Create GOAWAY frame (RFC 7540 §6.8) *)
let make_goaway ~last_stream_id ~error_code ~debug_data : t =
  let debug_len = String.length debug_data in
  let payload = Cstruct.create (8 + debug_len) in
  Cstruct.BE.set_uint32 payload 0 (Int32.logand last_stream_id 0x7FFFFFFFl);
  Cstruct.BE.set_uint32 payload 4 error_code;
  Cstruct.blit_from_string debug_data 0 payload 8 debug_len;
  {
    header = {
      length = 8 + debug_len;
      frame_type = GoAway;
      flags = 0;
      stream_id = 0l;
    };
    payload;
  }

(** Create CONTINUATION frame (RFC 7540 §6.10)
    Used when headers exceed max_frame_size *)
let make_continuation ~stream_id ~end_headers (payload : Cstruct.t) : t =
  let flags = if end_headers then Flags.end_headers else 0 in
  {
    header = {
      length = Cstruct.length payload;
      frame_type = Continuation;
      flags;
      stream_id;
    };
    payload;
  }

(** Split large header block into HEADERS + CONTINUATION frames
    @param max_frame_size Maximum payload size per frame (default 16384)
    @return List of frames: [HEADERS; CONTINUATION; ...; CONTINUATION] *)
let make_headers_fragmented ~stream_id ~end_stream ?(max_frame_size = 16384)
    ?priority (header_block : Cstruct.t) : t list =
  let total_len = Cstruct.length header_block in
  let priority_len = if Option.is_some priority then 5 else 0 in
  let first_max = max_frame_size - priority_len in
  if first_max <= 0 then
    invalid_arg "max_frame_size too small for priority block";
  if total_len <= first_max then
    (* Fits in single HEADERS frame *)
    [match priority with
     | Some p -> make_headers_with_priority ~stream_id ~end_stream ~end_headers:true ~priority:p header_block
     | None -> make_headers ~stream_id ~end_stream ~end_headers:true header_block]
  else begin
    (* Split into HEADERS + CONTINUATION frames *)
    let frames = ref [] in
    let offset = ref 0 in
    let first = ref true in

    while !offset < total_len do
      let remaining = total_len - !offset in
      let chunk_size =
        if !first then min remaining first_max else min remaining max_frame_size
      in
      let chunk = Cstruct.sub header_block !offset chunk_size in
      let is_last = !offset + chunk_size >= total_len in

      let frame =
        if !first then begin
          first := false;
          (* First frame: HEADERS with END_HEADERS=0 *)
          match priority with
          | Some p -> make_headers_with_priority ~stream_id ~end_stream ~end_headers:is_last ~priority:p chunk
          | None -> make_headers ~stream_id ~end_stream ~end_headers:is_last chunk
        end else
          (* Subsequent frames: CONTINUATION *)
          make_continuation ~stream_id ~end_headers:is_last chunk
      in
      frames := frame :: !frames;
      offset := !offset + chunk_size
    done;

    List.rev !frames
  end

(** Split PUSH_PROMISE header block into PUSH_PROMISE + CONTINUATION frames *)
let make_push_promise_fragmented ~stream_id ~promised_stream_id
    ?(max_frame_size = 16384) (header_block : Cstruct.t) : t list =
  let total_len = Cstruct.length header_block in
  let first_max = max_frame_size - 4 in
  if first_max <= 0 then
    invalid_arg "max_frame_size too small for PUSH_PROMISE";
  if total_len <= first_max then
    [make_push_promise ~stream_id ~promised_stream_id ~end_headers:true header_block]
  else begin
    let frames = ref [] in
    let offset = ref 0 in
    let first = ref true in

    while !offset < total_len do
      let remaining = total_len - !offset in
      let chunk_size =
        if !first then min remaining first_max else min remaining max_frame_size
      in
      let chunk = Cstruct.sub header_block !offset chunk_size in
      let is_last = !offset + chunk_size >= total_len in

      let frame =
        if !first then begin
          first := false;
          make_push_promise ~stream_id ~promised_stream_id ~end_headers:is_last chunk
        end else
          make_continuation ~stream_id ~end_headers:is_last chunk
      in
      frames := frame :: !frames;
      offset := !offset + chunk_size
    done;

    List.rev !frames
  end

(** Serialize frame to buffer (returns Cstruct for zero-copy write) *)
let to_cstruct (frame : t) : Cstruct.t =
  let total_len = header_size + frame.header.length in
  let buf = Cstruct.create total_len in
  write_header buf frame.header;
  Cstruct.blit frame.payload 0 buf header_size frame.header.length;
  buf

(** Serialize frame using pooled buffer *)
let to_cstruct_pooled (frame : t) : Cstruct.t =
  let total_len = header_size + frame.header.length in
  let buf = Buffer_pool.Cstruct_pool.acquire ~size:total_len in
  write_header buf frame.header;
  Cstruct.blit frame.payload 0 buf header_size frame.header.length;
  Cstruct.sub buf 0 total_len

(** gRPC error codes (subset) *)
module Error_code = struct
  let no_error = 0l
  let protocol_error = 1l
  let internal_error = 2l
  let flow_control_error = 3l
  let settings_timeout = 4l
  let stream_closed = 5l
  let frame_size_error = 6l
  let refused_stream = 7l
  let cancel = 8l
  let compression_error = 9l
  let connect_error = 10l
  let enhance_your_calm = 11l  (* Rate limiting *)
  let inadequate_security = 12l
  let http_1_1_required = 13l
end

(** SETTINGS identifiers *)
module Settings_id = struct
  let header_table_size = 0x1
  let enable_push = 0x2
  let max_concurrent_streams = 0x3
  let initial_window_size = 0x4
  let max_frame_size = 0x5
  let max_header_list_size = 0x6
end
