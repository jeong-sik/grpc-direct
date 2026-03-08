(** Tests for grpc-core status codes *)

let test_status_codes () =
  (* Test all gRPC status codes have correct integer values *)
  let open Grpc_core.Status in
  assert (code_to_int OK = 0);
  assert (code_to_int Cancelled = 1);
  assert (code_to_int Unknown = 2);
  assert (code_to_int Invalid_argument = 3);
  assert (code_to_int Deadline_exceeded = 4);
  assert (code_to_int Not_found = 5);
  assert (code_to_int Already_exists = 6);
  assert (code_to_int Permission_denied = 7);
  assert (code_to_int Resource_exhausted = 8);
  assert (code_to_int Failed_precondition = 9);
  assert (code_to_int Aborted = 10);
  assert (code_to_int Out_of_range = 11);
  assert (code_to_int Unimplemented = 12);
  assert (code_to_int Internal = 13);
  assert (code_to_int Unavailable = 14);
  assert (code_to_int Data_loss = 15);
  assert (code_to_int Unauthenticated = 16);
  Printf.printf "  ✓ Status code values (RFC compliant): OK\n%!"
;;

let test_code_from_int () =
  let open Grpc_core.Status in
  assert (code_of_int 0 = OK);
  assert (code_of_int 1 = Cancelled);
  assert (code_of_int 12 = Unimplemented);
  assert (code_of_int 16 = Unauthenticated);
  (* Unknown codes should map to Unknown *)
  assert (code_of_int 99 = Unknown);
  assert (code_of_int (-1) = Unknown);
  Printf.printf "  ✓ Code from int: OK\n%!"
;;

let test_status_creation () =
  let open Grpc_core.Status in
  let status = { code = Not_found; message = "Resource not found"; details = None } in
  assert (status.code = Not_found);
  assert (status.message = "Resource not found");
  assert (status.details = None);
  Printf.printf "  ✓ Status creation: OK\n%!"
;;

let test_status_with_details () =
  let open Grpc_core.Status in
  let status =
    { code = Invalid_argument
    ; message = "Invalid field value"
    ; details = Some "field 'email' must be valid email format"
    }
  in
  assert (status.code = Invalid_argument);
  assert (status.details = Some "field 'email' must be valid email format");
  Printf.printf "  ✓ Status with details: OK\n%!"
;;

let test_ok_status () =
  let open Grpc_core.Status in
  assert (ok.code = OK);
  assert (ok.message = "");
  assert (is_ok ok);
  Printf.printf "  ✓ OK status helper: OK\n%!"
;;

let test_error_helper () =
  let open Grpc_core.Status in
  let err = error Not_found "User not found" in
  assert (err.code = Not_found);
  assert (err.message = "User not found");
  assert (not (is_ok err));
  let err_with_details = error ~details:"id=123" Internal "Server error" in
  assert (err_with_details.details = Some "id=123");
  Printf.printf "  ✓ Error helper function: OK\n%!"
;;

let test_to_string () =
  let open Grpc_core.Status in
  let status = { code = Not_found; message = "User not found"; details = None } in
  let str = to_string status in
  assert (String.sub str 0 9 = "NOT_FOUND");
  Printf.printf "  ✓ Status to_string: OK\n%!"
;;

let test_common_error_statuses () =
  let open Grpc_core.Status in
  (* Test common error scenarios *)
  let _not_found = error Not_found "User not found" in
  let _invalid_arg = error Invalid_argument "Missing required field" in
  let _unauthenticated = error Unauthenticated "Invalid token" in
  let _permission_denied = error Permission_denied "Access denied" in
  let _internal = error Internal "Server error" in
  let _deadline = error Deadline_exceeded "Request timeout" in
  Printf.printf "  ✓ Common error statuses: OK\n%!"
;;

let () =
  Printf.printf "\n=== grpc-status tests ===\n\n%!";
  Printf.printf "📊 Status codes:\n%!";
  test_status_codes ();
  test_code_from_int ();
  Printf.printf "\n🏗️ Status creation:\n%!";
  test_status_creation ();
  test_status_with_details ();
  test_ok_status ();
  test_error_helper ();
  test_to_string ();
  test_common_error_statuses ();
  Printf.printf "\n=== All status tests passed! ===\n%!"
;;
