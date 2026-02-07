(** Tests for retry policy, backoff calculation, budget, and with_retry. *)

open Grpc_eio

(* --- Pure tests (no Eio runtime needed) --- *)

let test_default_policy () =
  let p = Retry.default_policy in
  assert (p.max_attempts = 3);
  assert (p.initial_backoff = 0.1);
  assert (p.max_backoff = 1.0);
  assert (p.backoff_multiplier = 2.0);
  assert (p.jitter = 0.2);
  assert (List.length p.retryable_codes = 3);
  Printf.printf "  OK default_policy fields\n%!"
;;

let test_simple_policy () =
  let p = Retry.simple ~max_attempts:5 in
  assert (p.max_attempts = 5);
  (* Inherits other defaults *)
  assert (p.initial_backoff = 0.1);
  assert (p.max_backoff = 1.0);
  Printf.printf "  OK simple policy\n%!"
;;

let test_aggressive_policy () =
  let p = Retry.aggressive in
  assert (p.max_attempts = 5);
  assert (p.initial_backoff = 0.05);
  assert (p.max_backoff = 2.0);
  assert (p.backoff_multiplier = 1.5);
  assert (p.jitter = 0.3);
  assert (List.length p.retryable_codes = 4);
  Printf.printf "  OK aggressive policy\n%!"
;;

let test_conservative_policy () =
  let p = Retry.conservative in
  assert (p.max_attempts = 2);
  assert (p.initial_backoff = 0.5);
  assert (p.max_backoff = 5.0);
  assert (p.backoff_multiplier = 3.0);
  assert (p.jitter = 0.1);
  assert (List.length p.retryable_codes = 1);
  Printf.printf "  OK conservative policy\n%!"
;;

let test_is_retryable () =
  let p = Retry.default_policy in
  (* Default retryable: Unavailable, Resource_exhausted, Aborted *)
  assert (Retry.is_retryable p Grpc_core.Status.Unavailable);
  assert (Retry.is_retryable p Grpc_core.Status.Resource_exhausted);
  assert (Retry.is_retryable p Grpc_core.Status.Aborted);
  (* Non-retryable *)
  assert (not (Retry.is_retryable p Grpc_core.Status.Not_found));
  assert (not (Retry.is_retryable p Grpc_core.Status.Internal));
  assert (not (Retry.is_retryable p Grpc_core.Status.OK));
  assert (not (Retry.is_retryable p Grpc_core.Status.Permission_denied));
  assert (not (Retry.is_retryable p Grpc_core.Status.Unauthenticated));
  Printf.printf "  OK is_retryable\n%!"
;;

let test_is_retryable_aggressive () =
  let p = Retry.aggressive in
  (* Aggressive adds Deadline_exceeded *)
  assert (Retry.is_retryable p Grpc_core.Status.Deadline_exceeded);
  assert (Retry.is_retryable p Grpc_core.Status.Unavailable);
  Printf.printf "  OK is_retryable aggressive\n%!"
;;

let test_is_retryable_conservative () =
  let p = Retry.conservative in
  (* Conservative only retries Unavailable *)
  assert (Retry.is_retryable p Grpc_core.Status.Unavailable);
  assert (not (Retry.is_retryable p Grpc_core.Status.Resource_exhausted));
  assert (not (Retry.is_retryable p Grpc_core.Status.Aborted));
  Printf.printf "  OK is_retryable conservative\n%!"
;;

let test_calculate_backoff_exponential () =
  (* Zero jitter for deterministic tests *)
  let p = { Retry.default_policy with jitter = 0.0 } in
  (* attempt 0: 0.1 * 2.0^0 = 0.1 *)
  let b0 = Retry.calculate_backoff p 0 in
  assert (abs_float (b0 -. 0.1) < 0.001);
  (* attempt 1: 0.1 * 2.0^1 = 0.2 *)
  let b1 = Retry.calculate_backoff p 1 in
  assert (abs_float (b1 -. 0.2) < 0.001);
  (* attempt 2: 0.1 * 2.0^2 = 0.4 *)
  let b2 = Retry.calculate_backoff p 2 in
  assert (abs_float (b2 -. 0.4) < 0.001);
  (* attempt 3: 0.1 * 2.0^3 = 0.8 *)
  let b3 = Retry.calculate_backoff p 3 in
  assert (abs_float (b3 -. 0.8) < 0.001);
  Printf.printf "  OK calculate_backoff exponential\n%!"
;;

let test_calculate_backoff_capped () =
  let p = { Retry.default_policy with jitter = 0.0; max_backoff = 0.3 } in
  (* attempt 0: min(0.1, 0.3) = 0.1 *)
  let b0 = Retry.calculate_backoff p 0 in
  assert (abs_float (b0 -. 0.1) < 0.001);
  (* attempt 2: min(0.1 * 4.0, 0.3) = min(0.4, 0.3) = 0.3 *)
  let b2 = Retry.calculate_backoff p 2 in
  assert (abs_float (b2 -. 0.3) < 0.001);
  (* attempt 10: still capped at 0.3 *)
  let b10 = Retry.calculate_backoff p 10 in
  assert (abs_float (b10 -. 0.3) < 0.001);
  Printf.printf "  OK calculate_backoff capped\n%!"
;;

let test_calculate_backoff_jitter_range () =
  let p = Retry.default_policy in
  (* jitter = 0.2 -> factor in [0.8, 1.2] *)
  (* For attempt 0, base = 0.1 -> range [0.08, 0.12] *)
  for _ = 1 to 50 do
    let b = Retry.calculate_backoff p 0 in
    assert (b >= (0.1 *. 0.8) -. 0.001);
    assert (b <= (0.1 *. 1.2) +. 0.001)
  done;
  Printf.printf "  OK calculate_backoff jitter in range\n%!"
;;

let test_budget_create_defaults () =
  let budget = Retry.Budget.create () in
  assert (Retry.Budget.remaining budget = 100);
  Printf.printf "  OK Budget.create defaults\n%!"
;;

let test_budget_create_custom () =
  let budget = Retry.Budget.create ~refill_interval:5.0 ~max_budget:50 () in
  assert (Retry.Budget.remaining budget = 50);
  Printf.printf "  OK Budget.create custom\n%!"
;;

let test_budget_try_acquire () =
  let budget = Retry.Budget.create ~max_budget:3 () in
  assert (Retry.Budget.remaining budget = 3);
  assert (Retry.Budget.try_acquire budget);
  assert (Retry.Budget.remaining budget = 2);
  assert (Retry.Budget.try_acquire budget);
  assert (Retry.Budget.remaining budget = 1);
  assert (Retry.Budget.try_acquire budget);
  assert (Retry.Budget.remaining budget = 0);
  (* Exhausted *)
  assert (not (Retry.Budget.try_acquire budget));
  assert (Retry.Budget.remaining budget = 0);
  Printf.printf "  OK Budget.try_acquire until exhausted\n%!"
;;

(* --- Eio-dependent tests --- *)

let test_with_retry_immediate_success () =
  Eio_main.run
  @@ fun _env ->
  let call_count = ref 0 in
  let result =
    Retry.with_retry (fun () ->
      incr call_count;
      Ok "success")
  in
  assert (result = Ok "success");
  assert (!call_count = 1);
  Printf.printf "  OK with_retry immediate success\n%!"
;;

let test_with_retry_retryable_then_success () =
  Eio_main.run
  @@ fun _env ->
  let call_count = ref 0 in
  let policy = { Retry.default_policy with initial_backoff = 0.001; jitter = 0.0 } in
  let result =
    Retry.with_retry ~policy (fun () ->
      incr call_count;
      if !call_count < 2
      then Error Grpc_core.Status.{ code = Unavailable; message = "down"; details = None }
      else Ok "recovered")
  in
  assert (result = Ok "recovered");
  assert (!call_count = 2);
  Printf.printf "  OK with_retry retryable then success\n%!"
;;

let test_with_retry_non_retryable () =
  Eio_main.run
  @@ fun _env ->
  let call_count = ref 0 in
  let result =
    Retry.with_retry (fun () ->
      incr call_count;
      Error Grpc_core.Status.{ code = Not_found; message = "not found"; details = None })
  in
  (match result with
   | Error s -> assert (s.code = Grpc_core.Status.Not_found)
   | Ok _ -> failwith "Expected error");
  assert (!call_count = 1);
  Printf.printf "  OK with_retry non-retryable stops immediately\n%!"
;;

let test_with_retry_max_attempts () =
  Eio_main.run
  @@ fun _env ->
  let call_count = ref 0 in
  let policy =
    { Retry.default_policy with max_attempts = 3; initial_backoff = 0.001; jitter = 0.0 }
  in
  let result =
    Retry.with_retry ~policy (fun () ->
      incr call_count;
      Error Grpc_core.Status.{ code = Unavailable; message = "down"; details = None })
  in
  (match result with
   | Error s -> assert (s.code = Grpc_core.Status.Unavailable)
   | Ok _ -> failwith "Expected error");
  (* 3 max_attempts = initial + 2 retries = 3 calls *)
  assert (!call_count = 3);
  Printf.printf "  OK with_retry max attempts exhausted\n%!"
;;

let test_with_retry_on_retry_callback () =
  Eio_main.run
  @@ fun _env ->
  let retry_log = ref [] in
  let call_count = ref 0 in
  let policy = { Retry.default_policy with initial_backoff = 0.001; jitter = 0.0 } in
  let on_retry attempt status _backoff =
    retry_log := (attempt, status.Grpc_core.Status.code) :: !retry_log
  in
  let _result =
    Retry.with_retry ~policy ~on_retry (fun () ->
      incr call_count;
      if !call_count < 3
      then Error Grpc_core.Status.{ code = Unavailable; message = "down"; details = None }
      else Ok "ok")
  in
  assert (List.length !retry_log = 2);
  Printf.printf "  OK with_retry on_retry callback invoked\n%!"
;;

let test_with_budget_success () =
  Eio_main.run
  @@ fun _env ->
  let budget = Retry.Budget.create ~max_budget:10 () in
  let result = Retry.with_budget ~budget (fun () -> Ok "ok") in
  assert (result = Ok "ok");
  Printf.printf "  OK with_budget success\n%!"
;;

let test_with_budget_exhausted () =
  Eio_main.run
  @@ fun _env ->
  let budget = Retry.Budget.create ~max_budget:1 () in
  let call_count = ref 0 in
  let policy =
    { Retry.default_policy with max_attempts = 5; initial_backoff = 0.001; jitter = 0.0 }
  in
  let result =
    Retry.with_budget ~policy ~budget (fun () ->
      incr call_count;
      Error Grpc_core.Status.{ code = Unavailable; message = "down"; details = None })
  in
  (match result with
   | Error s -> assert (s.code = Grpc_core.Status.Unavailable)
   | Ok _ -> failwith "Expected error");
  (* Budget allows 1 retry token: initial + 1 retry = 2 calls *)
  assert (!call_count = 2);
  Printf.printf "  OK with_budget exhausted limits retries\n%!"
;;

let () =
  Printf.printf "\n=== retry tests ===\n\n%!";
  Printf.printf "Policy configuration:\n%!";
  test_default_policy ();
  test_simple_policy ();
  test_aggressive_policy ();
  test_conservative_policy ();
  Printf.printf "\nRetryable code detection:\n%!";
  test_is_retryable ();
  test_is_retryable_aggressive ();
  test_is_retryable_conservative ();
  Printf.printf "\nBackoff calculation:\n%!";
  test_calculate_backoff_exponential ();
  test_calculate_backoff_capped ();
  test_calculate_backoff_jitter_range ();
  Printf.printf "\nBudget tracking:\n%!";
  test_budget_create_defaults ();
  test_budget_create_custom ();
  test_budget_try_acquire ();
  Printf.printf "\nResult-based retry:\n%!";
  test_with_retry_immediate_success ();
  test_with_retry_retryable_then_success ();
  test_with_retry_non_retryable ();
  test_with_retry_max_attempts ();
  test_with_retry_on_retry_callback ();
  Printf.printf "\nBudget-limited retry:\n%!";
  test_with_budget_success ();
  test_with_budget_exhausted ();
  Printf.printf "\n=== All retry tests passed ===\n%!"
;;
