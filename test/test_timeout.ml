(** Tests for grpc-core timeout (int64 nanoseconds) *)

let test_parse_valid () =
  let open Grpc_core.Timeout in
  let cases =
    [ "30S", of_seconds 30
    ; "100m", of_milliseconds 100
    ; "1H", Int64.mul 1L h
    ; "60M", Int64.mul 60L m
    ; "1000u", Int64.mul 1000L us
    ; "500n", 500L
    ]
  in
  List.iter
    (fun (input, expected) ->
       match parse input with
       | Some t when t = expected -> Printf.printf "  ✓ %s -> %Ld ns\n%!" input t
       | Some t -> failwith (Printf.sprintf "%s: got %Ld, expected %Ld" input t expected)
       | None -> failwith (Printf.sprintf "Failed to parse: %s" input))
    cases;
  Printf.printf "✅ Valid timeout parsing: OK\n%!"
;;

let test_parse_invalid () =
  let invalid = [ ""; "S"; "30X"; "999999999H"; "-30S"; "30.5S"; "abcS" ] in
  List.iter
    (fun input ->
       match Grpc_core.Timeout.parse input with
       | Some _ -> failwith ("Should have failed: " ^ input)
       | None -> Printf.printf "  ✓ %s -> None\n%!" input)
    invalid;
  Printf.printf "✅ Invalid rejection: OK\n%!"
;;

let test_conversions () =
  let open Grpc_core.Timeout in
  let t = of_seconds 30 in
  assert (to_seconds t = 30.0);
  assert (to_milliseconds t = 30000);
  assert (to_nanoseconds t = Int64.mul 30L s);
  Printf.printf "✅ Conversions: OK\n%!";
  assert (to_string (of_seconds 30) = "30S");
  assert (to_string (of_milliseconds 500) = "500m");
  Printf.printf "✅ to_string: OK\n%!"
;;

let test_defaults () =
  let open Grpc_core.Timeout in
  assert (default = of_seconds 30);
  Printf.printf "✅ Default (30S): OK\n%!";
  assert (infinite > Int64.mul 1000000L h);
  Printf.printf "✅ Infinite: OK\n%!"
;;

let () =
  Printf.printf "\n=== timeout tests ===\n\n%!";
  test_parse_valid ();
  test_parse_invalid ();
  test_conversions ();
  test_defaults ();
  Printf.printf "\n=== All passed! ===\n%!"
;;
