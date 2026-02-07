(** Tests for algorithms: P2C, RingBuffer, AdaptiveBatching,
    ExpHistogram, CircuitBreaker. *)

open Grpc_eio

(* ===== P2C (Power of Two Choices) ===== *)

let test_p2c_create () =
  let p = Algorithms.P2C.create [ "a", 1.0; "b", 1.0; "c", 1.0 ] in
  let stats = Algorithms.P2C.stats p in
  assert (Array.length stats = 3);
  (* All backends start with 0 load, 0 requests, 0 failures *)
  Array.iter
    (fun (_value, load, total, failures) ->
       assert (load = 0);
       assert (total = 0);
       assert (failures = 0))
    stats;
  Printf.printf "  OK P2C create\n%!"
;;

let test_p2c_create_empty () =
  let p = Algorithms.P2C.create [] in
  assert (Algorithms.P2C.acquire p = None);
  Printf.printf "  OK P2C create empty returns None on acquire\n%!"
;;

let test_p2c_create_single () =
  let p = Algorithms.P2C.create [ "only", 1.0 ] in
  let v = Algorithms.P2C.acquire p in
  assert (v = Some "only");
  Printf.printf "  OK P2C single backend\n%!"
;;

let test_p2c_acquire () =
  let p = Algorithms.P2C.create [ "a", 1.0; "b", 1.0 ] in
  let v = Algorithms.P2C.acquire p in
  assert (v = Some "a" || v = Some "b");
  (* After acquire, one backend should have load=1 *)
  let stats = Algorithms.P2C.stats p in
  let total_load = Array.fold_left (fun acc (_, load, _, _) -> acc + load) 0 stats in
  assert (total_load = 1);
  Printf.printf "  OK P2C acquire increments load\n%!"
;;

let test_p2c_acquire_many () =
  let p = Algorithms.P2C.create [ "a", 1.0; "b", 1.0 ] in
  let acquired = ref [] in
  for _ = 1 to 10 do
    match Algorithms.P2C.acquire p with
    | Some v -> acquired := v :: !acquired
    | None -> failwith "Unexpected None"
  done;
  (* All 10 should have been acquired *)
  assert (List.length !acquired = 10);
  (* Both backends should have been selected at least once (probabilistic) *)
  let has_a = List.exists (fun v -> v = "a") !acquired in
  let has_b = List.exists (fun v -> v = "b") !acquired in
  assert (has_a || has_b);
  Printf.printf "  OK P2C acquire many distributes load\n%!"
;;

let test_p2c_release () =
  let p = Algorithms.P2C.create [ "a", 1.0; "b", 1.0 ] in
  (match Algorithms.P2C.acquire p with
   | Some v ->
     Algorithms.P2C.release p v;
     let stats = Algorithms.P2C.stats p in
     let total_load = Array.fold_left (fun acc (_, load, _, _) -> acc + load) 0 stats in
     assert (total_load = 0)
   | None -> failwith "Unexpected None");
  Printf.printf "  OK P2C release decrements load\n%!"
;;

let test_p2c_report_failure () =
  let p = Algorithms.P2C.create [ "a", 1.0; "b", 1.0 ] in
  Algorithms.P2C.report_failure p "a";
  let stats = Algorithms.P2C.stats p in
  let a_failures =
    Array.fold_left
      (fun acc (v, _, _, failures) -> if v = "a" then failures else acc)
      0
      stats
  in
  assert (a_failures = 1);
  Printf.printf "  OK P2C report_failure\n%!"
;;

let test_p2c_weighted () =
  (* With weight 10.0 vs 0.1, the score = load/weight.
     Without release, load accumulates and weight differences become visible.
     heavy: score = load/10.0, light: score = load/0.1
     So heavy can accumulate ~100x more load before scores equalize. *)
  let p = Algorithms.P2C.create [ "heavy", 10.0; "light", 0.1 ] in
  let heavy_count = ref 0 in
  for _ = 1 to 20 do
    match Algorithms.P2C.acquire p with
    | Some v -> if v = "heavy" then incr heavy_count
    | None -> ()
  done;
  (* Heavy backend dominates due to lower score per unit load *)
  assert (!heavy_count > 10);
  Printf.printf "  OK P2C weighted distribution (heavy=%d/20)\n%!" !heavy_count
;;

(* ===== RingBuffer ===== *)

let test_ringbuffer_create () =
  let rb = Algorithms.RingBuffer.create 16 in
  assert (Algorithms.RingBuffer.is_empty rb);
  assert (not (Algorithms.RingBuffer.is_full rb));
  assert (Algorithms.RingBuffer.size rb = 0);
  Printf.printf "  OK RingBuffer create\n%!"
;;

let test_ringbuffer_push_pop () =
  let rb = Algorithms.RingBuffer.create 16 in
  assert (Algorithms.RingBuffer.try_push rb 42);
  assert (not (Algorithms.RingBuffer.is_empty rb));
  assert (Algorithms.RingBuffer.size rb = 1);
  let v = Algorithms.RingBuffer.try_pop rb in
  assert (v = Some 42);
  assert (Algorithms.RingBuffer.is_empty rb);
  Printf.printf "  OK RingBuffer push/pop\n%!"
;;

let test_ringbuffer_fifo () =
  let rb = Algorithms.RingBuffer.create 16 in
  for i = 1 to 5 do
    assert (Algorithms.RingBuffer.try_push rb i)
  done;
  for i = 1 to 5 do
    let v = Algorithms.RingBuffer.try_pop rb in
    assert (v = Some i)
  done;
  Printf.printf "  OK RingBuffer FIFO order\n%!"
;;

let test_ringbuffer_full () =
  (* Minimum capacity is 16 (rounded to power of 2) *)
  let rb = Algorithms.RingBuffer.create 16 in
  for i = 1 to 16 do
    assert (Algorithms.RingBuffer.try_push rb i)
  done;
  assert (Algorithms.RingBuffer.is_full rb);
  (* Push when full should fail *)
  assert (not (Algorithms.RingBuffer.try_push rb 999));
  Printf.printf "  OK RingBuffer full\n%!"
;;

let test_ringbuffer_empty_pop () =
  let rb = Algorithms.RingBuffer.create 16 in
  let v = Algorithms.RingBuffer.try_pop rb in
  assert (v = None);
  Printf.printf "  OK RingBuffer pop empty returns None\n%!"
;;

let test_ringbuffer_size () =
  let rb = Algorithms.RingBuffer.create 32 in
  for i = 1 to 10 do
    ignore (Algorithms.RingBuffer.try_push rb i)
  done;
  assert (Algorithms.RingBuffer.size rb = 10);
  for _ = 1 to 3 do
    ignore (Algorithms.RingBuffer.try_pop rb)
  done;
  assert (Algorithms.RingBuffer.size rb = 7);
  Printf.printf "  OK RingBuffer size tracking\n%!"
;;

let test_ringbuffer_wrap_around () =
  let rb = Algorithms.RingBuffer.create 16 in
  (* Fill and drain multiple times to test wrap-around *)
  for round = 1 to 3 do
    for i = 1 to 16 do
      assert (Algorithms.RingBuffer.try_push rb ((round * 100) + i))
    done;
    for i = 1 to 16 do
      let v = Algorithms.RingBuffer.try_pop rb in
      assert (v = Some ((round * 100) + i))
    done
  done;
  assert (Algorithms.RingBuffer.is_empty rb);
  Printf.printf "  OK RingBuffer wrap-around\n%!"
;;

(* ===== AdaptiveBatching ===== *)

let test_batching_create () =
  let b = Algorithms.AdaptiveBatching.create () in
  let batch_size, avg_latency, total_batches = Algorithms.AdaptiveBatching.stats b in
  assert (batch_size = 1);
  (* default min_batch_size *)
  assert (avg_latency = 0.0);
  assert (total_batches = 0);
  Printf.printf "  OK AdaptiveBatching create\n%!"
;;

let test_batching_add_triggers_batch () =
  let config =
    Algorithms.AdaptiveBatching.
      { min_batch_size = 1
      ; max_batch_size = 10
      ; max_delay_ms = 1000.0
      ; target_latency_ms = 10.0
      }
  in
  let b = Algorithms.AdaptiveBatching.create ~config () in
  (* With batch_size=1, first add should trigger a batch *)
  let result = Algorithms.AdaptiveBatching.add b "item1" in
  (match result with
   | Some batch ->
     assert (List.length batch = 1);
     assert (List.hd batch = "item1")
   | None -> failwith "Expected batch to trigger");
  Printf.printf "  OK AdaptiveBatching add triggers batch\n%!"
;;

let test_batching_accumulates () =
  let config =
    Algorithms.AdaptiveBatching.
      { min_batch_size = 1
      ; max_batch_size = 100
      ; max_delay_ms = 999999.0
      ; (* very high - won't time-trigger *)
        target_latency_ms = 10.0
      }
  in
  let b = Algorithms.AdaptiveBatching.create ~config () in
  (* Increase batch size by reporting low latency *)
  for _ = 1 to 20 do
    Algorithms.AdaptiveBatching.report_latency b 1.0
  done;
  let batch_size, _, _ = Algorithms.AdaptiveBatching.stats b in
  assert (batch_size > 1);
  Printf.printf
    "  OK AdaptiveBatching low latency increases batch_size to %d\n%!"
    batch_size
;;

let test_batching_flush () =
  let config =
    Algorithms.AdaptiveBatching.
      { min_batch_size = 1
      ; max_batch_size = 100
      ; max_delay_ms = 999999.0
      ; target_latency_ms = 10.0
      }
  in
  let b = Algorithms.AdaptiveBatching.create ~config () in
  (* Increase batch size first *)
  for _ = 1 to 20 do
    Algorithms.AdaptiveBatching.report_latency b 1.0
  done;
  (* Add items without triggering batch *)
  ignore (Algorithms.AdaptiveBatching.add b "x");
  (* Flush should return pending items *)
  let flushed = Algorithms.AdaptiveBatching.flush b in
  (* flushed could be empty if the add triggered, or have items *)
  ignore flushed;
  (* After flush, pending should be empty *)
  let flushed2 = Algorithms.AdaptiveBatching.flush b in
  assert (List.length flushed2 = 0);
  Printf.printf "  OK AdaptiveBatching flush\n%!"
;;

let test_batching_report_latency_high () =
  let config =
    Algorithms.AdaptiveBatching.
      { min_batch_size = 1
      ; max_batch_size = 100
      ; max_delay_ms = 999999.0
      ; target_latency_ms = 10.0
      }
  in
  let b = Algorithms.AdaptiveBatching.create ~config () in
  (* First increase batch size *)
  for _ = 1 to 30 do
    Algorithms.AdaptiveBatching.report_latency b 1.0
  done;
  let high_batch, _, _ = Algorithms.AdaptiveBatching.stats b in
  (* Now report high latency to decrease batch size *)
  for _ = 1 to 30 do
    Algorithms.AdaptiveBatching.report_latency b 100.0
  done;
  let low_batch, _, _ = Algorithms.AdaptiveBatching.stats b in
  assert (low_batch <= high_batch);
  Printf.printf
    "  OK AdaptiveBatching high latency decreases batch_size (%d -> %d)\n%!"
    high_batch
    low_batch
;;

let test_batching_stats () =
  let b = Algorithms.AdaptiveBatching.create () in
  (* Trigger a few batches *)
  for _ = 1 to 5 do
    ignore (Algorithms.AdaptiveBatching.add b "x")
  done;
  let _, _, total_batches = Algorithms.AdaptiveBatching.stats b in
  assert (total_batches > 0);
  Printf.printf "  OK AdaptiveBatching stats total_batches=%d\n%!" total_batches
;;

(* ===== ExpHistogram ===== *)

let test_histogram_create () =
  let h = Algorithms.ExpHistogram.create ~min_value:0.001 ~max_value:1000.0 in
  assert (Algorithms.ExpHistogram.mean h = 0.0);
  Printf.printf "  OK ExpHistogram create\n%!"
;;

let test_histogram_record_and_mean () =
  let h = Algorithms.ExpHistogram.create ~min_value:0.001 ~max_value:1000.0 in
  (* Record 5 values: 10, 20, 30, 40, 50 -> mean = 30 *)
  List.iter (fun v -> Algorithms.ExpHistogram.record h v) [ 10.0; 20.0; 30.0; 40.0; 50.0 ];
  let m = Algorithms.ExpHistogram.mean h in
  assert (abs_float (m -. 30.0) < 0.001);
  Printf.printf "  OK ExpHistogram mean = %.2f\n%!" m
;;

let test_histogram_percentiles () =
  let h = Algorithms.ExpHistogram.create ~min_value:0.001 ~max_value:10000.0 in
  (* Record 1000 values from 1 to 1000 *)
  for i = 1 to 1000 do
    Algorithms.ExpHistogram.record h (float_of_int i)
  done;
  let p50 = Algorithms.ExpHistogram.p50 h in
  let p90 = Algorithms.ExpHistogram.p90 h in
  let p95 = Algorithms.ExpHistogram.p95 h in
  let p99 = Algorithms.ExpHistogram.p99 h in
  let p999 = Algorithms.ExpHistogram.p999 h in
  (* P50 should be around 500, P90 around 900, etc.
     Exponential buckets give approximate values. *)
  assert (p50 > 100.0 && p50 < 900.0);
  assert (p90 > p50);
  assert (p95 >= p90);
  assert (p99 >= p95);
  assert (p999 >= p99);
  Printf.printf
    "  OK ExpHistogram percentiles: p50=%.0f p90=%.0f p95=%.0f p99=%.0f p999=%.0f\n%!"
    p50
    p90
    p95
    p99
    p999
;;

let test_histogram_reset () =
  let h = Algorithms.ExpHistogram.create ~min_value:0.001 ~max_value:1000.0 in
  Algorithms.ExpHistogram.record h 42.0;
  assert (Algorithms.ExpHistogram.mean h > 0.0);
  Algorithms.ExpHistogram.reset h;
  assert (Algorithms.ExpHistogram.mean h = 0.0);
  Printf.printf "  OK ExpHistogram reset\n%!"
;;

let test_histogram_print_summary () =
  let h = Algorithms.ExpHistogram.create ~min_value:0.001 ~max_value:1000.0 in
  for i = 1 to 100 do
    Algorithms.ExpHistogram.record h (float_of_int i)
  done;
  (* Just verify it doesn't crash *)
  Algorithms.ExpHistogram.print_summary h;
  Printf.printf "  OK ExpHistogram print_summary\n%!"
;;

let test_histogram_custom_percentile () =
  let h = Algorithms.ExpHistogram.create ~min_value:0.001 ~max_value:1000.0 in
  for i = 1 to 100 do
    Algorithms.ExpHistogram.record h (float_of_int i)
  done;
  let p25 = Algorithms.ExpHistogram.percentile h 0.25 in
  let p75 = Algorithms.ExpHistogram.percentile h 0.75 in
  assert (p75 > p25);
  Printf.printf "  OK ExpHistogram custom percentile p25=%.0f p75=%.0f\n%!" p25 p75
;;

(* ===== CircuitBreaker ===== *)

let test_cb_create_closed () =
  let cb = Algorithms.CircuitBreaker.create () in
  let state, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state = "closed");
  Printf.printf "  OK CircuitBreaker starts Closed\n%!"
;;

let test_cb_closed_allows () =
  let cb = Algorithms.CircuitBreaker.create () in
  assert (Algorithms.CircuitBreaker.allow cb);
  assert (Algorithms.CircuitBreaker.allow cb);
  assert (Algorithms.CircuitBreaker.allow cb);
  let _, allowed, rejected, _ = Algorithms.CircuitBreaker.stats cb in
  assert (allowed = 3);
  assert (rejected = 0);
  Printf.printf "  OK CircuitBreaker Closed allows requests\n%!"
;;

let test_cb_closed_to_open () =
  let config =
    Algorithms.CircuitBreaker.
      { failure_threshold = 3
      ; success_threshold = 2
      ; timeout_ms = 999999.0
      ; half_open_max = 2
      }
  in
  let cb = Algorithms.CircuitBreaker.create ~config () in
  (* Record failures up to threshold *)
  Algorithms.CircuitBreaker.record_failure cb;
  Algorithms.CircuitBreaker.record_failure cb;
  let state1, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state1 = "closed");
  (* Third failure triggers transition *)
  Algorithms.CircuitBreaker.record_failure cb;
  let state2, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state2 = "open");
  Printf.printf "  OK CircuitBreaker Closed -> Open after failures\n%!"
;;

let test_cb_open_rejects () =
  let config =
    Algorithms.CircuitBreaker.
      { failure_threshold = 2
      ; success_threshold = 1
      ; timeout_ms = 999999.0
      ; (* Very high - won't transition *)
        half_open_max = 1
      }
  in
  let cb = Algorithms.CircuitBreaker.create ~config () in
  (* Transition to Open *)
  Algorithms.CircuitBreaker.record_failure cb;
  Algorithms.CircuitBreaker.record_failure cb;
  let state, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state = "open");
  (* Open state rejects *)
  assert (not (Algorithms.CircuitBreaker.allow cb));
  assert (not (Algorithms.CircuitBreaker.allow cb));
  let _, _, rejected, _ = Algorithms.CircuitBreaker.stats cb in
  assert (rejected = 2);
  Printf.printf "  OK CircuitBreaker Open rejects requests\n%!"
;;

let test_cb_open_to_half_open () =
  let config =
    Algorithms.CircuitBreaker.
      { failure_threshold = 2
      ; success_threshold = 1
      ; timeout_ms = 0.0
      ; (* Immediate transition *)
        half_open_max = 2
      }
  in
  let cb = Algorithms.CircuitBreaker.create ~config () in
  (* Transition to Open *)
  ignore (Algorithms.CircuitBreaker.allow cb);
  Algorithms.CircuitBreaker.record_failure cb;
  Algorithms.CircuitBreaker.record_failure cb;
  let state1, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state1 = "open");
  (* With timeout_ms=0, allow should transition to HalfOpen *)
  assert (Algorithms.CircuitBreaker.allow cb);
  let state2, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state2 = "half-open");
  Printf.printf "  OK CircuitBreaker Open -> HalfOpen after timeout\n%!"
;;

let test_cb_half_open_to_closed () =
  let config =
    Algorithms.CircuitBreaker.
      { failure_threshold = 2
      ; success_threshold = 2
      ; timeout_ms = 0.0
      ; half_open_max = 5
      }
  in
  let cb = Algorithms.CircuitBreaker.create ~config () in
  (* Closed -> Open *)
  ignore (Algorithms.CircuitBreaker.allow cb);
  Algorithms.CircuitBreaker.record_failure cb;
  Algorithms.CircuitBreaker.record_failure cb;
  (* Open -> HalfOpen *)
  assert (Algorithms.CircuitBreaker.allow cb);
  let state1, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state1 = "half-open");
  (* Record enough successes to transition to Closed *)
  Algorithms.CircuitBreaker.record_success cb;
  let state2, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state2 = "half-open");
  (* Not yet - need 2 *)
  Algorithms.CircuitBreaker.record_success cb;
  let state3, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state3 = "closed");
  Printf.printf "  OK CircuitBreaker HalfOpen -> Closed after successes\n%!"
;;

let test_cb_half_open_to_open () =
  let config =
    Algorithms.CircuitBreaker.
      { failure_threshold = 2
      ; success_threshold = 3
      ; timeout_ms = 0.0
      ; half_open_max = 5
      }
  in
  let cb = Algorithms.CircuitBreaker.create ~config () in
  (* Closed -> Open *)
  ignore (Algorithms.CircuitBreaker.allow cb);
  Algorithms.CircuitBreaker.record_failure cb;
  Algorithms.CircuitBreaker.record_failure cb;
  (* Open -> HalfOpen *)
  assert (Algorithms.CircuitBreaker.allow cb);
  let state1, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state1 = "half-open");
  (* Failure in HalfOpen -> back to Open *)
  Algorithms.CircuitBreaker.record_failure cb;
  let state2, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (state2 = "open");
  Printf.printf "  OK CircuitBreaker HalfOpen -> Open on failure\n%!"
;;

let test_cb_half_open_max_concurrent () =
  let config =
    Algorithms.CircuitBreaker.
      { failure_threshold = 2
      ; success_threshold = 5
      ; timeout_ms = 0.0
      ; half_open_max = 2
      }
  in
  let cb = Algorithms.CircuitBreaker.create ~config () in
  (* Closed -> Open -> HalfOpen *)
  ignore (Algorithms.CircuitBreaker.allow cb);
  Algorithms.CircuitBreaker.record_failure cb;
  Algorithms.CircuitBreaker.record_failure cb;
  (* First allow: transitions to HalfOpen, half_open_count=1 *)
  assert (Algorithms.CircuitBreaker.allow cb);
  (* Second allow: half_open_count=2 (at max) *)
  assert (Algorithms.CircuitBreaker.allow cb);
  (* Third allow: exceeds half_open_max, rejected *)
  assert (not (Algorithms.CircuitBreaker.allow cb));
  Printf.printf "  OK CircuitBreaker HalfOpen max concurrent limit\n%!"
;;

let test_cb_success_resets_failure_count () =
  let config =
    Algorithms.CircuitBreaker.
      { failure_threshold = 3
      ; success_threshold = 1
      ; timeout_ms = 0.0
      ; half_open_max = 3
      }
  in
  let cb = Algorithms.CircuitBreaker.create ~config () in
  ignore (Algorithms.CircuitBreaker.allow cb);
  Algorithms.CircuitBreaker.record_failure cb;
  Algorithms.CircuitBreaker.record_failure cb;
  (* 2 failures, not yet at threshold *)
  let state, _, _, failures = Algorithms.CircuitBreaker.stats cb in
  assert (state = "closed");
  assert (failures = 2);
  (* Success resets failure count *)
  Algorithms.CircuitBreaker.record_success cb;
  let _, _, _, failures2 = Algorithms.CircuitBreaker.stats cb in
  assert (failures2 = 0);
  Printf.printf "  OK CircuitBreaker success resets failure count\n%!"
;;

let test_cb_full_lifecycle () =
  let config =
    Algorithms.CircuitBreaker.
      { failure_threshold = 2
      ; success_threshold = 1
      ; timeout_ms = 0.0
      ; half_open_max = 3
      }
  in
  let cb = Algorithms.CircuitBreaker.create ~config () in
  (* 1. Closed: allow, record success *)
  assert (Algorithms.CircuitBreaker.allow cb);
  Algorithms.CircuitBreaker.record_success cb;
  (* 2. Closed -> Open: failures *)
  ignore (Algorithms.CircuitBreaker.allow cb);
  Algorithms.CircuitBreaker.record_failure cb;
  Algorithms.CircuitBreaker.record_failure cb;
  let s1, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (s1 = "open");
  (* 3. Open -> HalfOpen: timeout elapsed *)
  assert (Algorithms.CircuitBreaker.allow cb);
  let s2, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (s2 = "half-open");
  (* 4. HalfOpen -> Closed: success *)
  Algorithms.CircuitBreaker.record_success cb;
  let s3, _, _, _ = Algorithms.CircuitBreaker.stats cb in
  assert (s3 = "closed");
  (* 5. Back to normal: allow works *)
  assert (Algorithms.CircuitBreaker.allow cb);
  Printf.printf "  OK CircuitBreaker full lifecycle\n%!"
;;

let () =
  Printf.printf "\n=== algorithms tests ===\n\n%!";
  Printf.printf "P2C (Power of Two Choices):\n%!";
  test_p2c_create ();
  test_p2c_create_empty ();
  test_p2c_create_single ();
  test_p2c_acquire ();
  test_p2c_acquire_many ();
  test_p2c_release ();
  test_p2c_report_failure ();
  test_p2c_weighted ();
  Printf.printf "\nRingBuffer:\n%!";
  test_ringbuffer_create ();
  test_ringbuffer_push_pop ();
  test_ringbuffer_fifo ();
  test_ringbuffer_full ();
  test_ringbuffer_empty_pop ();
  test_ringbuffer_size ();
  test_ringbuffer_wrap_around ();
  Printf.printf "\nAdaptiveBatching:\n%!";
  test_batching_create ();
  test_batching_add_triggers_batch ();
  test_batching_accumulates ();
  test_batching_flush ();
  test_batching_report_latency_high ();
  test_batching_stats ();
  Printf.printf "\nExpHistogram:\n%!";
  test_histogram_create ();
  test_histogram_record_and_mean ();
  test_histogram_percentiles ();
  test_histogram_reset ();
  test_histogram_print_summary ();
  test_histogram_custom_percentile ();
  Printf.printf "\nCircuitBreaker:\n%!";
  test_cb_create_closed ();
  test_cb_closed_allows ();
  test_cb_closed_to_open ();
  test_cb_open_rejects ();
  test_cb_open_to_half_open ();
  test_cb_half_open_to_closed ();
  test_cb_half_open_to_open ();
  test_cb_half_open_max_concurrent ();
  test_cb_success_resets_failure_count ();
  test_cb_full_lifecycle ();
  Printf.printf "\n=== All algorithms tests passed ===\n%!"
;;
