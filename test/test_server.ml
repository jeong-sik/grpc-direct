(** Minimal test server to reproduce :status header error *)

let echo_handler request =
  Printf.printf "Received: %s\n%!" request;
  Printf.sprintf "{\"echo\":\"%s\"}" request
;;

let () =
  Printf.printf "Starting grpc-direct test server on port 9940...\n%!";
  let service = Grpc_eio.Service.create "test.EchoService"
    |> Grpc_eio.Service.add_unary "Echo" echo_handler
  in
  let config : Grpc_eio.Server.config =
    { host = "127.0.0.1"
    ; port = 9940
    ; codecs = [ Grpc_core.Codec.identity ]
    ; max_message_size = 4 * 1024 * 1024
    ; default_timeout = Some Grpc_core.Timeout.default
    ; tls = None (* Plaintext mode *)
    }
  in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let server = Grpc_eio.Server.create ~config () |> Grpc_eio.Server.add_service service in
  Printf.printf "Server ready. Test with:\n";
  Printf.printf "  grpcurl -plaintext -d '{}' localhost:9940 test.EchoService/Echo\n%!";
  Grpc_eio.Server.serve ~sw ~env server
;;
