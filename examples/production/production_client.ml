(** Production-style gRPC client example.

    Run with:
      dune exec examples/production/production_client.exe

    Optional target:
      TARGET=http://127.0.0.1:50051 \
      dune exec examples/production/production_client.exe
*)

let target () =
  match Sys.getenv_opt "TARGET" with
  | Some v -> v
  | None -> "http://127.0.0.1:50051"

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->

  let config = Grpc_eio.Client.default_config ~target:(target ()) in
  let client = Grpc_eio.Client.connect ~config ~sw ~env (target ()) in

  let policy = Grpc_eio.Retry.{
    max_attempts = 3;
    initial_backoff = 0.05;
    max_backoff = 0.5;
    backoff_multiplier = 2.0;
    retryable_codes = [Unavailable; Resource_exhausted];
    jitter = 0.2;
  } in

  let client =
    client
    |> Grpc_eio.Client.with_interceptor (Grpc_eio.Retry.interceptor ~policy ())
  in

  let request = "hello" in
  match Grpc_eio.Client.call_unary ~sw ~env client
      ~service:"example.Echo"
      ~method_:"Echo"
      ~request
  with
  | Ok response ->
      Printf.printf "response: %s\n%!" response
  | Error status ->
      Printf.printf "error: %s\n%!" (Grpc_core.Status.to_string status)
