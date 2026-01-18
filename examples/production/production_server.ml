(** Production-style gRPC server example.

    Run with:
      dune exec examples/production/production_server.exe

    Optional TLS:
      TLS=1 CERT=./server.pem KEY=./server.key \
      dune exec examples/production/production_server.exe
*)

module EchoRequest = struct
  type t = { message : string }

  let of_bytes bytes = { message = String.trim bytes }
end

module EchoResponse = struct
  type t = { message : string }

  let to_bytes t = t.message
end

module EchoImpl = struct
  let echo (request : EchoRequest.t) : EchoResponse.t =
    { EchoResponse.message = request.message }
end

let tls_config () =
  match Sys.getenv_opt "TLS", Sys.getenv_opt "CERT", Sys.getenv_opt "KEY" with
  | Some "1", Some cert_file, Some key_file ->
      let tls = Grpc_eio.Tls_config.create ~cert_file ~key_file in
      Some tls
  | _ -> None

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->

  let metrics = Grpc_eio.Metrics.create () in
  let health = Grpc_eio.Health.create () in
  Grpc_eio.Health.set_status health ~service:"example.Echo" Grpc_eio.Health.Serving;

  let echo_service =
    Grpc_eio.Service.create "example.Echo"
    |> Grpc_eio.Service.add_unary "Echo" (fun bytes ->
        let request = EchoRequest.of_bytes bytes in
        let response = EchoImpl.echo request in
        EchoResponse.to_bytes response
      )
  in

  let config =
    match tls_config () with
    | None -> Grpc_eio.Server.default_config
    | Some tls -> { Grpc_eio.Server.default_config with tls = Some tls }
  in

  let server =
    Grpc_eio.Reflection.create_server_with_reflection ~config ()
    |> Grpc_eio.Server.add_service echo_service
    |> Grpc_eio.Server.add_service (Grpc_eio.Health.to_service health)
    |> Grpc_eio.Server.with_metrics metrics
    |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
  in

  Eio.Fiber.fork ~sw (fun () ->
    Grpc_eio.Metrics.serve_prometheus ~sw ~env metrics
  );

  Printf.printf "gRPC server on :50051 (metrics on :9464)\n%!";
  Grpc_eio.Server.serve ~sw ~env server
