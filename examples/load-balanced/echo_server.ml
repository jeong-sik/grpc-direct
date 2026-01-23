(** Echo Server - Simple server for load balancing demo

    Run multiple instances on different ports:
      PORT=50051 dune exec examples/load-balanced/echo_server.exe
      PORT=50052 dune exec examples/load-balanced/echo_server.exe
      PORT=50053 dune exec examples/load-balanced/echo_server.exe

    This demonstrates:
    - Configurable port via environment variable
    - Simple echo service for testing load distribution
*)

(** Get port from environment or default *)
let get_port () =
  match Sys.getenv_opt "PORT" with
  | Some p -> int_of_string p
  | None -> 50051
;;

(** Echo handler - returns message with server identity *)
let echo port (request : string) : string =
  let server_id = Printf.sprintf "server-%d" port in
  Printf.sprintf "%s|from:%s|time:%f" request server_id (Unix.gettimeofday ())
;;

let () =
  let port = get_port () in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  (* Create echo service *)
  let echo_service =
    Grpc_eio.Service.create "demo.EchoService"
    |> Grpc_eio.Service.add_unary "Echo" (echo port)
  in
  (* Create health service *)
  let health = Grpc_eio.Health.create () in
  Grpc_eio.Health.set_status health ~service:"" Grpc_eio.Health.Serving;
  Grpc_eio.Health.set_status health ~service:"demo.EchoService" Grpc_eio.Health.Serving;
  (* Configure server *)
  let config = Grpc_eio.Server.{ default_config with port } in
  let server =
    Grpc_eio.Server.create ~config ()
    |> Grpc_eio.Server.add_service echo_service
    |> Grpc_eio.Server.add_service (Grpc_eio.Health.to_service health)
    |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
  in
  Printf.printf "🔄 Echo Server [port %d]\n%!" port;
  Printf.printf "─────────────────────────────────────────\n%!";
  Printf.printf "   Service: demo.EchoService\n%!";
  Printf.printf "   Health: grpc.health.v1.Health\n%!";
  Printf.printf "\n%!";
  Printf.printf "Start more servers:\n%!";
  Printf.printf "  PORT=50052 dune exec examples/load-balanced/echo_server.exe\n%!";
  Printf.printf "  PORT=50053 dune exec examples/load-balanced/echo_server.exe\n%!";
  Grpc_eio.Server.serve ~sw ~env server
;;
