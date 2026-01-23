(** gRPC-Web server example.

    Run:
      dune exec examples/grpc-web/grpc_web_server.exe

    Ports:
      - gRPC (HTTP/2): 50051
      - gRPC-Web (HTTP/1.1): 8080
      - gRPC-Web (WebSocket): 8082 *)

module Message = struct
  type t =
    { content : string
    ; seq : int
    }

  let of_bytes bytes =
    match String.split_on_char ':' bytes with
    | [ seq_str; content ] -> { seq = int_of_string seq_str; content }
    | _ -> { seq = 0; content = bytes }
  ;;

  let to_bytes t = Printf.sprintf "%d:%s" t.seq t.content
end

module EchoService = struct
  let echo bytes =
    let msg = Message.of_bytes bytes in
    Message.to_bytes { msg with content = "Echo: " ^ msg.content }
  ;;

  let echo_stream bytes =
    let msg = Message.of_bytes bytes in
    let stream = Grpc_eio.Stream.create 8 in
    for i = 1 to 3 do
      let payload = Message.to_bytes { Message.seq = i; content = msg.content } in
      Grpc_eio.Stream.add stream payload
    done;
    Grpc_eio.Stream.close stream;
    stream
  ;;

  let echo_collect request_stream =
    let count = ref 0 in
    let contents = ref [] in
    let rec drain () =
      match Grpc_eio.Stream.take request_stream with
      | bytes ->
        let msg = Message.of_bytes bytes in
        incr count;
        contents := msg.content :: !contents;
        drain ()
      | exception End_of_file -> ()
    in
    drain ();
    let summary =
      Printf.sprintf "Collected %d: [%s]" !count (String.concat ", " (List.rev !contents))
    in
    Message.to_bytes { Message.seq = !count; content = summary }
  ;;

  let echo_bidi request_stream =
    let response_stream = Grpc_eio.Stream.create 8 in
    let rec drain () =
      match Grpc_eio.Stream.take request_stream with
      | bytes ->
        let msg = Message.of_bytes bytes in
        let response = Message.to_bytes { msg with content = "Bidi: " ^ msg.content } in
        Grpc_eio.Stream.add response_stream response;
        drain ()
      | exception End_of_file -> Grpc_eio.Stream.close response_stream
    in
    drain ();
    response_stream
  ;;
end

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let service =
    Grpc_eio.Service.create "web.Echo"
    |> Grpc_eio.Service.add_unary "Echo" EchoService.echo
    |> Grpc_eio.Service.add_server_streaming "EchoStream" EchoService.echo_stream
    |> Grpc_eio.Service.add_client_streaming "EchoCollect" EchoService.echo_collect
    |> Grpc_eio.Service.add_bidi_streaming "EchoBidi" EchoService.echo_bidi
  in
  let server = Grpc_eio.Server.create () |> Grpc_eio.Server.add_service service in
  (* Run gRPC (HTTP/2) and gRPC-Web (HTTP/1.1) side by side. *)
  Eio.Fiber.fork ~sw (fun () -> Grpc_eio.Server.serve ~sw ~env server);
  let web_config =
    Grpc_eio.Grpc_web_server.
      { addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 8080)
      ; cors = default_cors
      ; tls = None
      ; max_request_body = 8 * 1024 * 1024
      }
  in
  let ws_config =
    Grpc_eio.Grpc_web_ws_server.
      { addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 8082)
      ; tls = None
      ; max_frame_size = 8 * 1024 * 1024
      ; subprotocols = [ "grpc-websockets" ]
      }
  in
  Eio.Fiber.fork ~sw (fun () ->
    Grpc_eio.Grpc_web_server.serve ~config:web_config ~sw ~env server);
  Grpc_eio.Grpc_web_ws_server.serve ~config:ws_config ~sw ~env server
;;
