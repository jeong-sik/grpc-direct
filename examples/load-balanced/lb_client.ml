(** Load-Balanced Client - Demonstrates client-side load balancing

    Run with: dune exec examples/load-balanced/lb_client.exe

    Before running, start multiple echo servers:
      PORT=50051 dune exec examples/load-balanced/echo_server.exe &
      PORT=50052 dune exec examples/load-balanced/echo_server.exe &
      PORT=50053 dune exec examples/load-balanced/echo_server.exe &

    This demonstrates:
    - Round Robin load balancing across multiple backends
    - Automatic failover when a backend is unhealthy
    - Request distribution visualization
*)

(** Parse echo response to extract server identity *)
let parse_response response =
  let parts = String.split_on_char '|' response in
  match parts with
  | msg :: rest ->
    let from_server =
      List.find_map
        (fun p ->
           if String.length p > 5 && String.sub p 0 5 = "from:"
           then Some (String.sub p 5 (String.length p - 5))
           else None)
        rest
      |> Option.value ~default:"unknown"
    in
    msg, from_server
  | _ -> response, "unknown"
;;

let () =
  Random.self_init ();
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Printf.printf "🔄 Load-Balanced Client\n%!";
  Printf.printf "─────────────────────────────────────────\n%!";
  (* Create load balancer with multiple backends *)
  let balancer =
    Grpc_eio.Balancer.create
      ~strategy:Grpc_eio.Balancer.RoundRobin
      ~targets:
        [ "http://127.0.0.1:50051"; "http://127.0.0.1:50052"; "http://127.0.0.1:50053" ]
      ()
  in
  Printf.printf "📡 Created balancer (Round Robin, 3 backends)\n%!";
  Printf.printf "   - http://127.0.0.1:50051\n%!";
  Printf.printf "   - http://127.0.0.1:50052\n%!";
  Printf.printf "   - http://127.0.0.1:50053\n%!";
  Printf.printf "\n%!";
  (* Track which servers handled requests *)
  let server_counts = Hashtbl.create 8 in
  (* Send multiple requests to see distribution *)
  let num_requests = 9 in
  Printf.printf "📤 Sending %d requests...\n\n%!" num_requests;
  for i = 1 to num_requests do
    let request = Printf.sprintf "Request-%d" i in
    try
      let response =
        Grpc_eio.Balancer.call ~sw ~env balancer (fun client ->
          match
            Grpc_eio.Client.call_unary
              ~sw
              ~env
              client
              ~service:"demo.EchoService"
              ~method_:"Echo"
              ~request
          with
          | Ok resp -> resp
          | Error status -> failwith status.Grpc_core.Status.message)
      in
      let msg, server = parse_response response in
      Printf.printf "   [%d] %s → %s\n%!" i msg server;
      (* Count requests per server *)
      let count = Hashtbl.find_opt server_counts server |> Option.value ~default:0 in
      Hashtbl.replace server_counts server (count + 1)
    with
    | exn -> Printf.printf "   [%d] ❌ Error: %s\n%!" i (Printexc.to_string exn)
  done;
  (* Show distribution summary *)
  Printf.printf "\n📊 Request Distribution:\n%!";
  Hashtbl.iter
    (fun server count ->
       let bar = String.make count '#' in
       Printf.printf "   %s: %d %s\n%!" server count bar)
    server_counts;
  (* Show backend status *)
  Printf.printf "\n📈 Backend Status:\n%!";
  let backends = Grpc_eio.Balancer.backends balancer in
  List.iter
    (fun (target, state) ->
       let state_str =
         match state with
         | Grpc_eio.Balancer.Healthy -> "✅ Healthy"
         | Grpc_eio.Balancer.Unhealthy -> "❌ Unhealthy"
         | Grpc_eio.Balancer.Unknown -> "❓ Unknown"
       in
       Printf.printf "   %s: %s\n%!" target state_str)
    backends;
  Printf.printf
    "   Healthy: %d/%d\n%!"
    (Grpc_eio.Balancer.healthy_count balancer)
    (Grpc_eio.Balancer.total_count balancer);
  Printf.printf "\n✅ Done\n%!"
;;
