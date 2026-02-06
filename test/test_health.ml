(** Tests for gRPC health checking service. *)

open Grpc_eio

let test_create_default () =
  let h = Health.create () in
  let status = Health.get_status h ~service:"" in
  assert (status = Health.Unknown);
  Printf.printf "  OK create default status is Unknown\n%!"
;;

let test_create_custom_default () =
  let h = Health.create ~default_status:Health.Serving () in
  let status = Health.get_status h ~service:"" in
  assert (status = Health.Serving);
  Printf.printf "  OK create with custom default Serving\n%!"
;;

let test_set_get_status () =
  let h = Health.create () in
  Health.set_status h ~service:"myapp.Greeter" Health.Serving;
  let s = Health.get_status h ~service:"myapp.Greeter" in
  assert (s = Health.Serving);
  Printf.printf "  OK set_status / get_status\n%!"
;;

let test_get_status_unknown_service () =
  let h = Health.create () in
  let s = Health.get_status h ~service:"unknown.Service" in
  assert (s = Health.Service_unknown);
  Printf.printf "  OK unknown service returns Service_unknown\n%!"
;;

let test_get_status_empty_returns_default () =
  let h = Health.create ~default_status:Health.Serving () in
  let s = Health.get_status h ~service:"" in
  assert (s = Health.Serving);
  Printf.printf "  OK empty string service returns default_status\n%!"
;;

let test_set_default_status () =
  let h = Health.create () in
  assert (Health.get_status h ~service:"" = Health.Unknown);
  Health.set_default_status h Health.Not_serving;
  let s = Health.get_status h ~service:"" in
  assert (s = Health.Not_serving);
  Printf.printf "  OK set_default_status\n%!"
;;

let test_register_service () =
  let h = Health.create () in
  Health.register_service h ~service:"svc1";
  Health.register_service h ~service:"svc2";
  let services = Health.list_services h in
  assert (List.length services = 2);
  assert (List.mem "svc1" services);
  assert (List.mem "svc2" services);
  Printf.printf "  OK register_service / list_services\n%!"
;;

let test_register_idempotent () =
  let h = Health.create () in
  Health.register_service h ~service:"svc1";
  Health.set_status h ~service:"svc1" Health.Serving;
  (* Re-registering should NOT reset the status *)
  Health.register_service h ~service:"svc1";
  let s = Health.get_status h ~service:"svc1" in
  assert (s = Health.Serving);
  Printf.printf "  OK register_service idempotent (no reset)\n%!"
;;

let test_list_services_empty () =
  let h = Health.create () in
  let services = Health.list_services h in
  assert (List.length services = 0);
  Printf.printf "  OK list_services empty\n%!"
;;

let test_set_all_serving () =
  let h = Health.create () in
  Health.set_status h ~service:"a" Health.Unknown;
  Health.set_status h ~service:"b" Health.Not_serving;
  Health.set_all_serving h;
  assert (Health.get_status h ~service:"a" = Health.Serving);
  assert (Health.get_status h ~service:"b" = Health.Serving);
  assert (Health.get_status h ~service:"" = Health.Serving);
  Printf.printf "  OK set_all_serving\n%!"
;;

let test_set_all_not_serving () =
  let h = Health.create () in
  Health.set_status h ~service:"x" Health.Serving;
  Health.set_status h ~service:"y" Health.Serving;
  Health.set_all_not_serving h;
  assert (Health.get_status h ~service:"x" = Health.Not_serving);
  assert (Health.get_status h ~service:"y" = Health.Not_serving);
  assert (Health.get_status h ~service:"" = Health.Not_serving);
  Printf.printf "  OK set_all_not_serving (graceful shutdown)\n%!"
;;

let test_status_transitions () =
  let h = Health.create () in
  Health.set_status h ~service:"svc" Health.Unknown;
  assert (Health.get_status h ~service:"svc" = Health.Unknown);
  Health.set_status h ~service:"svc" Health.Serving;
  assert (Health.get_status h ~service:"svc" = Health.Serving);
  Health.set_status h ~service:"svc" Health.Not_serving;
  assert (Health.get_status h ~service:"svc" = Health.Not_serving);
  Health.set_status h ~service:"svc" Health.Service_unknown;
  assert (Health.get_status h ~service:"svc" = Health.Service_unknown);
  Printf.printf "  OK status transitions\n%!"
;;

let test_multiple_services () =
  let h = Health.create () in
  Health.set_status h ~service:"auth" Health.Serving;
  Health.set_status h ~service:"db" Health.Not_serving;
  Health.set_status h ~service:"cache" Health.Unknown;
  assert (Health.get_status h ~service:"auth" = Health.Serving);
  assert (Health.get_status h ~service:"db" = Health.Not_serving);
  assert (Health.get_status h ~service:"cache" = Health.Unknown);
  let services = Health.list_services h in
  assert (List.length services = 3);
  Printf.printf "  OK multiple services independent\n%!"
;;

(* --- Eio-dependent tests --- *)

let test_watch_initial_status () =
  Eio_main.run @@ fun _env ->
  let h = Health.create () in
  Health.set_status h ~service:"watched" Health.Serving;
  let stream = Health.watch h ~service:"watched" in
  (* Watch sends initial status immediately *)
  let initial = Grpc_eio.Stream.take_nonblocking stream in
  assert (initial = Some Health.Serving);
  Printf.printf "  OK watch sends initial status\n%!"
;;

let test_watch_notification () =
  Eio_main.run @@ fun _env ->
  let h = Health.create () in
  Health.set_status h ~service:"s1" Health.Serving;
  let stream = Health.watch h ~service:"s1" in
  (* Drain initial status *)
  ignore (Grpc_eio.Stream.take_nonblocking stream);
  (* Update status -> watcher should be notified *)
  Health.set_status h ~service:"s1" Health.Not_serving;
  let update = Grpc_eio.Stream.take_nonblocking stream in
  assert (update = Some Health.Not_serving);
  Printf.printf "  OK watch notification on status change\n%!"
;;

let test_to_service_check_method () =
  let h = Health.create () in
  Health.set_status h ~service:"myservice" Health.Serving;
  let service = Health.to_service h in
  let methods = Service.list_methods service in
  assert (List.mem "Check" methods);
  assert (List.mem "Watch" methods);
  match Service.get_method service "Check" with
  | None -> failwith "Check method not found"
  | Some method_def ->
    (match method_def.handler with
     | `Unary handler ->
       (* Test 1: Empty request -> overall server health (Unknown default) *)
       let response = handler "" in
       assert (String.length response = 2);
       (* Byte 0 = tag (8), Byte 1 = status enum value *)
       (* Unknown = 0 *)
       assert (Char.code response.[1] = 0);
       (* Test 2: Named service request *)
       let svc_name = "myservice" in
       let request =
         String.make 1 (Char.chr 10)
         ^ (* tag: field 1, wire type 2 *)
         String.make 1 (Char.chr (String.length svc_name))
         ^ svc_name
       in
       let response2 = handler request in
       assert (String.length response2 = 2);
       (* Serving = 1 *)
       assert (Char.code response2.[1] = 1);
       Printf.printf "  OK to_service Check handler\n%!"
     | _ -> failwith "Expected unary handler")
;;

let test_to_service_check_not_found () =
  let h = Health.create () in
  let service = Health.to_service h in
  match Service.get_method service "Check" with
  | None -> failwith "Check method not found"
  | Some method_def ->
    (match method_def.handler with
     | `Unary handler ->
       (* Request for unregistered service *)
       let svc_name = "nonexistent" in
       let request =
         String.make 1 (Char.chr 10)
         ^ String.make 1 (Char.chr (String.length svc_name))
         ^ svc_name
       in
       let response = handler request in
       (* Service_unknown = 3 *)
       assert (Char.code response.[1] = 3);
       Printf.printf "  OK to_service Check returns Service_unknown\n%!"
     | _ -> failwith "Expected unary handler")
;;

let () =
  Printf.printf "\n=== health tests ===\n\n%!";
  Printf.printf "Basic operations:\n%!";
  test_create_default ();
  test_create_custom_default ();
  test_set_get_status ();
  test_get_status_unknown_service ();
  test_get_status_empty_returns_default ();
  test_set_default_status ();
  Printf.printf "\nService registration:\n%!";
  test_register_service ();
  test_register_idempotent ();
  test_list_services_empty ();
  Printf.printf "\nBulk operations:\n%!";
  test_set_all_serving ();
  test_set_all_not_serving ();
  Printf.printf "\nState transitions:\n%!";
  test_status_transitions ();
  test_multiple_services ();
  Printf.printf "\nWatch (streaming):\n%!";
  test_watch_initial_status ();
  test_watch_notification ();
  Printf.printf "\nService integration:\n%!";
  test_to_service_check_method ();
  test_to_service_check_not_found ();
  Printf.printf "\n=== All health tests passed ===\n%!"
;;
