(** HTTP/2 Stream State Machine (RFC 7540 §5.1)

    Stream States:
                             +--------+
                     send PP |        | recv PP
                    ,--------|  idle  |--------.
                   /         |        |         \
                  v          +--------+          v
           +----------+          |           +----------+
           |          |          | send H /  |          |
    ,------| reserved |          | recv H    | reserved |------.
    |      | (local)  |          |           | (remote) |      |
    |      +----------+          v           +----------+      |
    |          |             +--------+             |          |
    |          |     recv ES |        | send ES    |          |
    |   send H |     ,-------|  open  |-------.    | recv H   |
    |          |    /        |        |        \   |          |
    |          v   v         +--------+         v  v          |
    |      +----------+          |           +----------+      |
    |      |   half   |          |           |   half   |      |
    |      |  closed  |          | send R /  |  closed  |      |
    |      | (remote) |          | recv R    | (local)  |      |
    |      +----------+          |           +----------+      |
    |           |                |                 |           |
    |           | send ES /      |       recv ES / |           |
    |           | send R /       v        send R / |           |
    |           | recv R     +--------+   recv R   |           |
    | send R /  `----------->|        |<-----------'  send R / |
    | recv R                 | closed |               recv R   |
    `----------------------->|        |<-----------------------'
                             +--------+

    H:  HEADERS frame (with implied CONTINUATIONs)
    PP: PUSH_PROMISE frame (with implied CONTINUATIONs)
    ES: END_STREAM flag
    R:  RST_STREAM frame
*)

(** Stream states *)
type state =
  | Idle
  | ReservedLocal
  | ReservedRemote
  | Open
  | HalfClosedLocal (* We sent END_STREAM *)
  | HalfClosedRemote (* They sent END_STREAM *)
  | Closed

let state_to_string = function
  | Idle -> "idle"
  | ReservedLocal -> "reserved (local)"
  | ReservedRemote -> "reserved (remote)"
  | Open -> "open"
  | HalfClosedLocal -> "half-closed (local)"
  | HalfClosedRemote -> "half-closed (remote)"
  | Closed -> "closed"
;;

(** Error type for invalid state transitions *)
type error =
  | ProtocolError of string
  | StreamClosed
  | InvalidTransition of state * string

exception Stream_error of error

(** Stream data.

    {b Thread Safety:}
    [mutex] protects [state], [send_window], and [recv_window] which can be
    accessed from both read and write fibers. [headers] and [data] are
    append-only from the read path. [priority] updates are infrequent and
    also protected by the mutex. *)
type t =
  { id : int32
  ; mutable state : state
  ; mutable send_window : int (* Flow control window *)
  ; mutable recv_window : int
  ; mutable priority : Frame.priority_info
  ; mutable headers : (string * string) list
  ; mutable data : Cstruct.t list (* Accumulated DATA frames *)
  ; mutex : Eio.Mutex.t
  }

(** Default initial window size (RFC 7540 §6.9.2) *)
let default_window_size = 65535

let default_priority : Frame.priority_info =
  { exclusive = false; dependency = 0l; weight = 16 }
;;

(** Create a new stream *)
let create ?(priority = default_priority) id =
  { id
  ; state = Idle
  ; send_window = default_window_size
  ; recv_window = default_window_size
  ; priority
  ; headers = []
  ; data = []
  ; mutex = Eio.Mutex.create ()
  }
;;

(** Update stream priority (RFC 7540 §5.3) *)
let set_priority t (priority : Frame.priority_info) =
  if priority.dependency = t.id
  then raise (Stream_error (ProtocolError "PRIORITY dependency on self"));
  if priority.weight < 1 || priority.weight > 256
  then raise (Stream_error (ProtocolError "PRIORITY weight out of range"));
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.priority <- priority)
;;

(** State transitions for sending frames.

    Protected by [mutex] to prevent concurrent read/write path races. *)
let transition_send t frame_type ~end_stream =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    match t.state, frame_type with
    (* From idle *)
    | Idle, `Headers -> t.state <- (if end_stream then HalfClosedLocal else Open)
    | Idle, `PushPromise -> t.state <- ReservedLocal
    (* From reserved (local) *)
    | ReservedLocal, `Headers ->
      t.state <- (if end_stream then Closed else HalfClosedRemote)
    | ReservedLocal, `RstStream -> t.state <- Closed
    (* From open *)
    | Open, `Data when end_stream -> t.state <- HalfClosedLocal
    | Open, `Headers when end_stream -> t.state <- HalfClosedLocal
    | Open, `RstStream -> t.state <- Closed
    | Open, _ -> () (* Stay open *)
    (* From half-closed (remote) - we can still send *)
    | HalfClosedRemote, `Data when end_stream -> t.state <- Closed
    | HalfClosedRemote, `Headers when end_stream -> t.state <- Closed
    | HalfClosedRemote, `RstStream -> t.state <- Closed
    | HalfClosedRemote, _ -> ()
    (* From half-closed (local) - we already sent END_STREAM *)
    | HalfClosedLocal, `RstStream -> t.state <- Closed
    | HalfClosedLocal, (`Data | `Headers) ->
      raise (Stream_error (InvalidTransition (t.state, "cannot send after END_STREAM")))
    (* From closed *)
    | Closed, `Priority -> () (* Only PRIORITY allowed *)
    | Closed, _ -> raise (Stream_error StreamClosed)
    | state, frame_type ->
      let frame_name =
        match frame_type with
        | `Headers -> "HEADERS"
        | `Data -> "DATA"
        | `RstStream -> "RST_STREAM"
        | `PushPromise -> "PUSH_PROMISE"
        | `Priority -> "PRIORITY"
        | `WindowUpdate -> "WINDOW_UPDATE"
      in
      raise (Stream_error (InvalidTransition (state, "send " ^ frame_name))))
;;

(** State transitions for receiving frames.

    Protected by [mutex] to prevent concurrent read/write path races. *)
let transition_recv t frame_type ~end_stream =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    match t.state, frame_type with
    (* From idle *)
    | Idle, `Headers -> t.state <- (if end_stream then HalfClosedRemote else Open)
    | Idle, `PushPromise -> t.state <- ReservedRemote
    | Idle, `Priority -> () (* Stay idle *)
    (* From reserved (remote) *)
    | ReservedRemote, `Headers ->
      t.state <- (if end_stream then Closed else HalfClosedLocal)
    | ReservedRemote, `RstStream -> t.state <- Closed
    (* From open *)
    | Open, `Data when end_stream -> t.state <- HalfClosedRemote
    | Open, `Headers when end_stream -> t.state <- HalfClosedRemote
    | Open, `RstStream -> t.state <- Closed
    | Open, _ -> ()
    (* From half-closed (local) - they can still send *)
    | HalfClosedLocal, `Data when end_stream -> t.state <- Closed
    | HalfClosedLocal, `Headers when end_stream -> t.state <- Closed
    | HalfClosedLocal, `RstStream -> t.state <- Closed
    | HalfClosedLocal, _ -> ()
    (* From half-closed (remote) - they already sent END_STREAM *)
    | HalfClosedRemote, `RstStream -> t.state <- Closed
    | HalfClosedRemote, (`Data | `Headers) ->
      raise (Stream_error (InvalidTransition (t.state, "received data after END_STREAM")))
    (* From closed *)
    | Closed, `Priority -> ()
    | Closed, _ -> raise (Stream_error StreamClosed)
    | state, frame_type ->
      let frame_name =
        match frame_type with
        | `Headers -> "HEADERS"
        | `Data -> "DATA"
        | `RstStream -> "RST_STREAM"
        | `PushPromise -> "PUSH_PROMISE"
        | `Priority -> "PRIORITY"
        | `WindowUpdate -> "WINDOW_UPDATE"
      in
      raise (Stream_error (InvalidTransition (state, "recv " ^ frame_name))))
;;

(** Create a stream in ReservedRemote state (PUSH_PROMISE received) *)
let create_reserved_remote ?(priority = default_priority) id =
  let t = create ~priority id in
  transition_recv t `PushPromise ~end_stream:false;
  t
;;

(** Create a stream in ReservedLocal state (PUSH_PROMISE sent) *)
let create_reserved_local ?(priority = default_priority) id =
  let t = create ~priority id in
  transition_send t `PushPromise ~end_stream:false;
  t
;;

(** Check if stream can send *)
let can_send t =
  Eio.Mutex.use_ro t.mutex (fun () ->
    match t.state with
    | Open | HalfClosedRemote -> true
    | _ -> false)
;;

(** Check if stream can receive *)
let can_recv t =
  Eio.Mutex.use_ro t.mutex (fun () ->
    match t.state with
    | Open | HalfClosedLocal -> true
    | _ -> false)
;;

(** Check if stream is done *)
let is_closed t = Eio.Mutex.use_ro t.mutex (fun () -> t.state = Closed)

(** Flow control: consume send window *)
let consume_send_window t bytes =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    if bytes > t.send_window
    then raise (Stream_error (ProtocolError "send window exhausted"));
    t.send_window <- t.send_window - bytes)
;;

(** Flow control: replenish recv window *)
let update_recv_window t bytes =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    t.recv_window <- t.recv_window + bytes)
;;

(** Flow control: update send window from WINDOW_UPDATE *)
let update_send_window t bytes =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    t.send_window <- t.send_window + bytes;
    (* Check overflow (RFC 7540 §6.9.1) *)
    if t.send_window > 2147483647
    then raise (Stream_error (ProtocolError "flow control window overflow")))
;;

(** Append data frame payload *)
let append_data t payload = t.data <- t.data @ [ payload ]

(** Get accumulated data *)
let get_data t =
  let total_len = List.fold_left (fun acc cs -> acc + Cstruct.length cs) 0 t.data in
  let result = Cstruct.create total_len in
  let _ =
    List.fold_left
      (fun off cs ->
         Cstruct.blit cs 0 result off (Cstruct.length cs);
         off + Cstruct.length cs)
      0
      t.data
  in
  result
;;
