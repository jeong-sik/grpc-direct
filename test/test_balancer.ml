(** Tests for load balancer: creation, backend state, health tracking. *)

open Grpc_eio

let test_create_empty_targets () =
  try
    ignore (Balancer.create ~targets:[] ());
    failwith "Expected failure for empty targets"
  with
  | Failure msg ->
    assert (String.length msg > 0);
    Printf.printf "  OK create with empty targets raises: %s\n%!" msg
;;

let test_create_roundrobin () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~targets:[ "s1"; "s2"; "s3" ] () in
  assert (Balancer.total_count b = 3);
  (* Unknown state is considered available *)
  assert (Balancer.healthy_count b = 3);
  Printf.printf "  OK create RoundRobin (default)\n%!"
;;

let test_create_pick_first () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~strategy:Balancer.PickFirst ~targets:[ "x"; "y" ] () in
  assert (Balancer.total_count b = 2);
  assert (Balancer.healthy_count b = 2);
  Printf.printf "  OK create PickFirst\n%!"
;;

let test_create_weighted () =
  Eio_main.run
  @@ fun _env ->
  let b =
    Balancer.create
      ~strategy:(Balancer.WeightedRoundRobin [ 3; 1 ])
      ~targets:[ "fast"; "slow" ]
      ()
  in
  assert (Balancer.total_count b = 2);
  Printf.printf "  OK create WeightedRoundRobin\n%!"
;;

let test_create_random () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~strategy:Balancer.Random ~targets:[ "a"; "b" ] () in
  assert (Balancer.total_count b = 2);
  Printf.printf "  OK create Random\n%!"
;;

let test_create_single_target () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~targets:[ "only-one" ] () in
  assert (Balancer.total_count b = 1);
  assert (Balancer.healthy_count b = 1);
  Printf.printf "  OK create single target\n%!"
;;

let test_create_custom_thresholds () =
  Eio_main.run
  @@ fun _env ->
  let b =
    Balancer.create
      ~health_check_interval:30.0
      ~failure_threshold:5
      ~recovery_threshold:3
      ~targets:[ "a"; "b" ]
      ()
  in
  assert (Balancer.total_count b = 2);
  Printf.printf "  OK create custom thresholds\n%!"
;;

let test_backends_initial_state () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~targets:[ "s1"; "s2" ] () in
  let bs = Balancer.backends b in
  assert (List.length bs = 2);
  (* All backends start in Unknown state *)
  assert (List.assoc "s1" bs = Balancer.Unknown);
  assert (List.assoc "s2" bs = Balancer.Unknown);
  Printf.printf "  OK backends initial state is Unknown\n%!"
;;

let test_mark_unhealthy () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~targets:[ "a"; "b"; "c" ] () in
  assert (Balancer.healthy_count b = 3);
  Balancer.mark_unhealthy b "b";
  assert (Balancer.healthy_count b = 2);
  let bs = Balancer.backends b in
  assert (List.assoc "b" bs = Balancer.Unhealthy);
  (* Others unchanged *)
  assert (List.assoc "a" bs = Balancer.Unknown);
  assert (List.assoc "c" bs = Balancer.Unknown);
  Printf.printf "  OK mark_unhealthy\n%!"
;;

let test_mark_healthy () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~targets:[ "a"; "b" ] () in
  Balancer.mark_unhealthy b "a";
  assert (Balancer.healthy_count b = 1);
  assert (List.assoc "a" (Balancer.backends b) = Balancer.Unhealthy);
  Balancer.mark_healthy b "a";
  assert (Balancer.healthy_count b = 2);
  assert (List.assoc "a" (Balancer.backends b) = Balancer.Healthy);
  Printf.printf "  OK mark_healthy restores backend\n%!"
;;

let test_mark_nonexistent_target () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~targets:[ "a" ] () in
  (* Marking nonexistent target should be a no-op *)
  Balancer.mark_unhealthy b "nonexistent";
  assert (Balancer.healthy_count b = 1);
  Balancer.mark_healthy b "nonexistent";
  assert (Balancer.healthy_count b = 1);
  Printf.printf "  OK mark nonexistent target is no-op\n%!"
;;

let test_mark_all_unhealthy () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~targets:[ "a"; "b"; "c" ] () in
  Balancer.mark_unhealthy b "a";
  Balancer.mark_unhealthy b "b";
  Balancer.mark_unhealthy b "c";
  assert (Balancer.healthy_count b = 0);
  assert (Balancer.total_count b = 3);
  Printf.printf "  OK all backends unhealthy -> healthy_count = 0\n%!"
;;

let test_to_string_roundrobin () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~targets:[ "host1"; "host2" ] () in
  let s = Balancer.to_string b in
  assert (String.length s > 0);
  Printf.printf "  OK to_string: %s\n%!" s
;;

let test_to_string_pick_first () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~strategy:Balancer.PickFirst ~targets:[ "h1" ] () in
  let s = Balancer.to_string b in
  assert (String.length s > 0);
  Printf.printf "  OK to_string PickFirst: %s\n%!" s
;;

let test_to_string_with_unhealthy () =
  Eio_main.run
  @@ fun _env ->
  let b = Balancer.create ~targets:[ "a"; "b" ] () in
  Balancer.mark_unhealthy b "b";
  let s = Balancer.to_string b in
  assert (String.length s > 0);
  Printf.printf "  OK to_string with unhealthy: %s\n%!" s
;;

let test_default_pool_options () =
  let opts = Balancer.default_pool_options in
  assert (opts.min_connections = 1);
  assert (opts.max_connections = 10);
  assert (opts.idle_timeout = 300.0);
  assert (opts.health_check_interval = 30.0);
  assert (opts.connection_timeout = 5.0);
  assert (opts.client_config = None);
  Printf.printf "  OK default_pool_options\n%!"
;;

let () =
  Printf.printf "\n=== balancer tests ===\n\n%!";
  Printf.printf "Creation:\n%!";
  test_create_empty_targets ();
  test_create_roundrobin ();
  test_create_pick_first ();
  test_create_weighted ();
  test_create_random ();
  test_create_single_target ();
  test_create_custom_thresholds ();
  Printf.printf "\nBackend state:\n%!";
  test_backends_initial_state ();
  test_mark_unhealthy ();
  test_mark_healthy ();
  test_mark_nonexistent_target ();
  test_mark_all_unhealthy ();
  Printf.printf "\nFormatting:\n%!";
  test_to_string_roundrobin ();
  test_to_string_pick_first ();
  test_to_string_with_unhealthy ();
  Printf.printf "\nPool options:\n%!";
  test_default_pool_options ();
  Printf.printf "\n=== All balancer tests passed ===\n%!"
;;
