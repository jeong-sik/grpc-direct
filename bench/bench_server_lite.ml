(** Minimal Echo Server using Server_lite (h2_lite backend)

    For benchmarking h2_lite's actual performance vs grpc-go.

    Usage:
      dune exec bench/bench_server_lite.exe

      # Then benchmark:
      ghz --insecure --proto bench/go-comparison/echo.proto \
          --call echo.EchoService/Echo -d '{"message":"hello"}' \
          -n 100000 -c 50 127.0.0.1:50099
*)

let port = 50099

(** Simple echo handler - return the same bytes *)
let echo_handler (request : string) : string =
  (* For echo.EchoRequest -> echo.EchoResponse,
     both have same structure (string message = 1),
     so we can return bytes as-is for maximum performance *)
  request

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->

  (* Create service with the correct name matching echo.proto *)
  let service = Grpc_eio.Service.create "echo.EchoService"
    |> Grpc_eio.Service.add_unary "Echo" echo_handler
  in

  Printf.printf "\n";
  Printf.printf "╔═══════════════════════════════════════════════════════╗\n";
  Printf.printf "║     grpc-eio Server_lite (h2_lite) Benchmark          ║\n";
  Printf.printf "╚═══════════════════════════════════════════════════════╝\n";
  Printf.printf "\n";
  Printf.printf "Server listening on port %d\n" port;
  Printf.printf "Backend: h2_lite (custom HTTP/2 implementation)\n";
  Printf.printf "Press Ctrl+C to stop\n";
  Printf.printf "\n";
  Printf.printf "Test with:\n";
  Printf.printf "  ghz --insecure --proto bench/go-comparison/echo.proto \\\n";
  Printf.printf "      --call echo.EchoService/Echo -d '{\"message\":\"hello\"}' \\\n";
  Printf.printf "      -n 100000 -c 50 127.0.0.1:%d\n" port;
  Printf.printf "\n";
  flush stdout;

  (* Start Server_lite (uses h2_lite internally) *)
  Grpc_eio.Server_lite.serve_service ~sw ~env ~port service
