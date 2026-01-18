(** HTTP/2 Flow Control (RFC 7540 §5.2)

    Flow control operates at two levels:
    1. Connection level: Shared window for all streams
    2. Stream level: Individual window per stream

    Key properties:
    - Initial window size: 65535 bytes (can be changed via SETTINGS)
    - Only DATA frames are subject to flow control
    - WINDOW_UPDATE frames add to the window
    - Window can be negative (after SETTINGS change)

    Flow control algorithm:
    1. Before sending DATA, check window >= data_size
    2. After sending DATA, subtract data_size from window
    3. On receiving WINDOW_UPDATE, add increment to window
    4. If window would exceed 2^31-1, send FLOW_CONTROL_ERROR
*)

(** Maximum window size (2^31 - 1) *)
let max_window_size = Int32.to_int 0x7FFFFFFFl

(** Default initial window size *)
let default_initial_window_size = 65535

(** Flow control window state *)
type window = {
  mutable size : int;         (* Current window size (can be negative) *)
  mutable initial : int;      (* Initial window size for new streams *)
  condition : Eio.Condition.t; (* For blocking when window exhausted *)
  mutex : Eio.Mutex.t;
}

(** Connection-level flow control *)
type t = {
  send_window : window;  (* Our send window (controlled by peer) *)
  recv_window : window;  (* Peer's send window (we control) *)
  send_stream_windows : (int32, window) Hashtbl.t;  (* Per-stream send windows *)
  recv_stream_windows : (int32, window) Hashtbl.t;  (* Per-stream recv windows *)
}

(** Create a new window *)
let create_window ?(initial = default_initial_window_size) () = {
  size = initial;
  initial;
  condition = Eio.Condition.create ();
  mutex = Eio.Mutex.create ();
}

(** Create flow control state *)
let create () = {
  send_window = create_window ();
  recv_window = create_window ();
  send_stream_windows = Hashtbl.create 16;
  recv_stream_windows = Hashtbl.create 16;
}

(** Get or create stream send window *)
let get_send_stream_window t stream_id =
  match Hashtbl.find_opt t.send_stream_windows stream_id with
  | Some w -> w
  | None ->
    let w = create_window ~initial:t.send_window.initial () in
    Hashtbl.add t.send_stream_windows stream_id w;
    w

(** Get or create stream recv window *)
let get_recv_stream_window t stream_id =
  match Hashtbl.find_opt t.recv_stream_windows stream_id with
  | Some w -> w
  | None ->
    let w = create_window ~initial:t.recv_window.initial () in
    Hashtbl.add t.recv_stream_windows stream_id w;
    w

(** Check if we can send data of given size *)
let can_send t stream_id size =
  let sw = get_send_stream_window t stream_id in
  t.send_window.size >= size && sw.size >= size

(** Wait until we can send *)
let wait_for_window t stream_id size =
  let sw = get_send_stream_window t stream_id in

  (* Wait for connection window *)
  Eio.Mutex.use_rw t.send_window.mutex ~protect:false (fun () ->
    while t.send_window.size < size do
      Eio.Condition.await_no_mutex t.send_window.condition
    done
  );

  (* Wait for stream window *)
  Eio.Mutex.use_rw sw.mutex ~protect:false (fun () ->
    while sw.size < size do
      Eio.Condition.await_no_mutex sw.condition
    done
  )

(** Consume window when sending DATA *)
let consume t stream_id size =
  let sw = get_send_stream_window t stream_id in

  Eio.Mutex.use_rw t.send_window.mutex ~protect:false (fun () ->
    t.send_window.size <- t.send_window.size - size
  );

  Eio.Mutex.use_rw sw.mutex ~protect:false (fun () ->
    sw.size <- sw.size - size
  )

(** Update window on WINDOW_UPDATE frame *)
let update t stream_id increment =
  if stream_id = 0l then begin
    (* Connection-level update *)
    Eio.Mutex.use_rw t.send_window.mutex ~protect:false (fun () ->
      let new_size = t.send_window.size + increment in
      if new_size > max_window_size then
        failwith "FLOW_CONTROL_ERROR: window overflow";
      t.send_window.size <- new_size;
      Eio.Condition.broadcast t.send_window.condition
    )
  end else begin
    (* Stream-level update *)
    let sw = get_send_stream_window t stream_id in
    Eio.Mutex.use_rw sw.mutex ~protect:false (fun () ->
      let new_size = sw.size + increment in
      if new_size > max_window_size then
        failwith "FLOW_CONTROL_ERROR: window overflow";
      sw.size <- new_size;
      Eio.Condition.broadcast sw.condition
    )
  end

(** Update recv window and return WINDOW_UPDATE increment if needed *)
let consume_recv t stream_id size =
  let threshold = t.recv_window.initial / 2 in  (* Update at 50% *)

  (* Track consumed bytes *)
  t.recv_window.size <- t.recv_window.size - size;

  let sw = get_recv_stream_window t stream_id in
  sw.size <- sw.size - size;

  (* Return update needed if below threshold *)
  let updates = ref [] in

  if t.recv_window.size < threshold then begin
    let increment = t.recv_window.initial - t.recv_window.size in
    t.recv_window.size <- t.recv_window.initial;
    updates := (0l, increment) :: !updates
  end;

  if sw.size < threshold then begin
    let increment = sw.initial - sw.size in
    sw.size <- sw.initial;
    updates := (stream_id, increment) :: !updates
  end;

  !updates

(** Handle SETTINGS initial window size change *)
let update_initial_window_size t new_size =
  let delta = new_size - t.send_window.initial in
  t.send_window.initial <- new_size;

  (* Update all existing stream windows *)
  Hashtbl.iter (fun _ sw ->
    Eio.Mutex.use_rw sw.mutex ~protect:false (fun () ->
      sw.size <- sw.size + delta;
      sw.initial <- new_size;
      if sw.size > 0 then
        Eio.Condition.broadcast sw.condition
    )
  ) t.send_stream_windows

(** Update recv initial window size (local SETTINGS) *)
let update_recv_initial_window_size t new_size =
  let delta = new_size - t.recv_window.initial in
  t.recv_window.initial <- new_size;
  t.recv_window.size <- t.recv_window.size + delta;

  Hashtbl.iter (fun _ sw ->
    sw.size <- sw.size + delta;
    sw.initial <- new_size
  ) t.recv_stream_windows

(** Remove stream window when stream closes *)
let remove_stream t stream_id =
  Hashtbl.remove t.send_stream_windows stream_id;
  Hashtbl.remove t.recv_stream_windows stream_id

(** Get current connection send window *)
let connection_send_window t = t.send_window.size

(** Get stream send window *)
let stream_send_window t stream_id =
  let sw = get_send_stream_window t stream_id in
  sw.size

(** Get stream recv window *)
let stream_recv_window t stream_id =
  let sw = get_recv_stream_window t stream_id in
  sw.size

(** Debug: print window states *)
let debug_print t =
  Printf.printf "Connection: send=%d recv=%d\n"
    t.send_window.size t.recv_window.size;
  Hashtbl.iter (fun id sw ->
    let recv = stream_recv_window t id in
    Printf.printf "  Stream %ld: send=%d recv=%d\n"
      id sw.size recv
  ) t.send_stream_windows
