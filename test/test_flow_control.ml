(** Tests for H2_lite.Flow_control — HTTP/2 flow control (RFC 7540 Section 5.2)

    Flow_control uses Eio.Mutex and Eio.Condition, so tests require Eio runtime.
    We test the pure-logic parts (window math, stream tracking) in Eio_main.run.
*)

open H2_lite

(* ── Constants ────────────────────────────────────────────────── *)

let test_constants () =
  assert (Flow_control.max_window_size = 2147483647);  (* 2^31 - 1 *)
  assert (Flow_control.default_initial_window_size = 65535);
  Printf.printf "PASS constants\n%!"
;;

(* ── create / create_window ───────────────────────────────────── *)

let test_create () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  assert (Flow_control.connection_send_window fc = 65535);
  Printf.printf "PASS create\n%!"
;;

(* ── can_send ─────────────────────────────────────────────────── *)

let test_can_send () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  (* Connection and stream windows start at 65535 *)
  assert (Flow_control.can_send fc 1l 1000);
  assert (Flow_control.can_send fc 1l 65535);
  assert (not (Flow_control.can_send fc 1l 65536));
  Printf.printf "PASS can_send\n%!"
;;

(* ── consume ──────────────────────────────────────────────────── *)

let test_consume () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  Flow_control.consume fc 1l 1000;
  assert (Flow_control.connection_send_window fc = 65535 - 1000);
  assert (Flow_control.stream_send_window fc 1l = 65535 - 1000);
  Printf.printf "PASS consume\n%!"
;;

let test_consume_multiple_streams () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  Flow_control.consume fc 1l 1000;
  Flow_control.consume fc 3l 2000;
  (* Connection window decremented by both *)
  assert (Flow_control.connection_send_window fc = 65535 - 3000);
  (* Stream windows decremented independently *)
  assert (Flow_control.stream_send_window fc 1l = 65535 - 1000);
  assert (Flow_control.stream_send_window fc 3l = 65535 - 2000);
  Printf.printf "PASS consume multiple streams\n%!"
;;

(* ── update (WINDOW_UPDATE handling) ──────────────────────────── *)

let test_update_connection () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  Flow_control.consume fc 1l 50000;
  assert (Flow_control.connection_send_window fc = 65535 - 50000);
  Flow_control.update fc 0l 50000;
  assert (Flow_control.connection_send_window fc = 65535);
  Printf.printf "PASS update connection window\n%!"
;;

let test_update_stream () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  Flow_control.consume fc 3l 30000;
  assert (Flow_control.stream_send_window fc 3l = 65535 - 30000);
  Flow_control.update fc 3l 30000;
  assert (Flow_control.stream_send_window fc 3l = 65535);
  Printf.printf "PASS update stream window\n%!"
;;

let test_update_overflow () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  (* Try to overflow the connection window *)
  (try
    Flow_control.update fc 0l Flow_control.max_window_size;
    assert false
  with Failure msg ->
    assert (String.length msg > 0));
  Printf.printf "PASS update overflow detection\n%!"
;;

let test_update_stream_overflow () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  (* Try to overflow a stream window *)
  (try
    Flow_control.update fc 1l Flow_control.max_window_size;
    assert false
  with Failure msg ->
    assert (String.length msg > 0));
  Printf.printf "PASS update stream overflow detection\n%!"
;;

(* ── consume_recv / WINDOW_UPDATE generation ──────────────────── *)

let test_consume_recv_no_update () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  (* Consume a small amount -- below 50% threshold *)
  let updates = Flow_control.consume_recv fc 1l 100 in
  assert (updates = []);
  Printf.printf "PASS consume_recv no update needed\n%!"
;;

let test_consume_recv_triggers_update () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  (* Consume more than 50% of window (65535 / 2 = 32767) *)
  let updates = Flow_control.consume_recv fc 1l 33000 in
  (* Should get WINDOW_UPDATE for both connection and stream *)
  assert (List.length updates >= 1);
  Printf.printf "PASS consume_recv triggers update (got %d updates)\n%!"
    (List.length updates)
;;

(* ── update_initial_window_size (SETTINGS change) ─────────────── *)

let test_update_initial_window_size () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  (* Create some stream windows *)
  Flow_control.consume fc 1l 1000;
  Flow_control.consume fc 3l 2000;
  let old_sw1 = Flow_control.stream_send_window fc 1l in
  let old_sw3 = Flow_control.stream_send_window fc 3l in
  (* Increase initial window size by 10000 *)
  Flow_control.update_initial_window_size fc (65535 + 10000);
  let new_sw1 = Flow_control.stream_send_window fc 1l in
  let new_sw3 = Flow_control.stream_send_window fc 3l in
  assert (new_sw1 = old_sw1 + 10000);
  assert (new_sw3 = old_sw3 + 10000);
  Printf.printf "PASS update_initial_window_size\n%!"
;;

(* ── update_recv_initial_window_size ──────────────────────────── *)

let test_update_recv_initial_window_size () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  let _ = Flow_control.stream_recv_window fc 1l in  (* Create stream *)
  let old_recv = Flow_control.stream_recv_window fc 1l in
  Flow_control.update_recv_initial_window_size fc (65535 + 5000);
  let new_recv = Flow_control.stream_recv_window fc 1l in
  assert (new_recv = old_recv + 5000);
  Printf.printf "PASS update_recv_initial_window_size\n%!"
;;

(* ── remove_stream ────────────────────────────────────────────── *)

let test_remove_stream () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  Flow_control.consume fc 1l 1000;
  assert (Flow_control.stream_send_window fc 1l = 65535 - 1000);
  Flow_control.remove_stream fc 1l;
  (* After removal, getting the window creates a fresh one *)
  assert (Flow_control.stream_send_window fc 1l = 65535);
  Printf.printf "PASS remove_stream\n%!"
;;

(* ── stream window isolation ──────────────────────────────────── *)

let test_stream_isolation () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  Flow_control.consume fc 1l 10000;
  Flow_control.consume fc 3l 20000;
  Flow_control.consume fc 5l 5000;
  assert (Flow_control.stream_send_window fc 1l = 65535 - 10000);
  assert (Flow_control.stream_send_window fc 3l = 65535 - 20000);
  assert (Flow_control.stream_send_window fc 5l = 65535 - 5000);
  assert (Flow_control.connection_send_window fc = 65535 - 35000);
  Printf.printf "PASS stream window isolation\n%!"
;;

(* ── debug_print (smoke test) ─────────────────────────────────── *)

let test_debug_print () =
  Eio_main.run @@ fun _env ->
  let fc = Flow_control.create () in
  Flow_control.consume fc 1l 100;
  (* Just make sure it does not crash *)
  Flow_control.debug_print fc;
  Printf.printf "PASS debug_print\n%!"
;;

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Printf.printf "\n=== Flow Control Tests (RFC 7540 Section 5.2) ===\n\n%!";
  test_constants ();
  test_create ();
  test_can_send ();
  test_consume ();
  test_consume_multiple_streams ();
  test_update_connection ();
  test_update_stream ();
  test_update_overflow ();
  test_update_stream_overflow ();
  test_consume_recv_no_update ();
  test_consume_recv_triggers_update ();
  test_update_initial_window_size ();
  test_update_recv_initial_window_size ();
  test_remove_stream ();
  test_stream_isolation ();
  test_debug_print ();
  Printf.printf "\n=== All Flow Control tests passed. ===\n%!"
;;
