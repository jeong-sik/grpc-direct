(** Example gRPC Server demonstrating all 4 RPC types.

    Run with: dune exec examples/streaming/streaming_server.exe

    This demonstrates:
    - Unary RPC: Single request, single response
    - Server Streaming: Single request, stream of responses
    - Client Streaming: Stream of requests, single response
    - Bidirectional Streaming: Stream of requests, stream of responses

    Test with examples/streaming/streaming_client.exe *)

(** Simple message type *)
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

(** Service implementation showing all 4 RPC patterns *)
module EchoService = struct
  (** Unary: Echo back the message *)
  let echo bytes =
    let msg = Message.of_bytes bytes in
    let response = { msg with content = "Echo: " ^ msg.content } in
    Message.to_bytes response
  ;;

  (** Server Streaming: Send N responses for one request *)
  let echo_expand bytes =
    let msg = Message.of_bytes bytes in
    let count = max 1 (min msg.seq 10) in
    (* Send 1-10 messages *)
    let stream = Grpc_eio.Stream.create 16 in
    for i = 1 to count do
      let response =
        { Message.seq = i; content = Printf.sprintf "Response %d: %s" i msg.content }
      in
      Grpc_eio.Stream.add stream (Message.to_bytes response)
    done;
    Grpc_eio.Stream.close stream;
    stream
  ;;

  (** Client Streaming: Collect all and return summary *)
  let echo_collect request_stream =
    let count = ref 0 in
    let contents = ref [] in
    (* Read all messages from stream *)
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
      Printf.sprintf
        "Received %d messages: [%s]"
        !count
        (String.concat ", " (List.rev !contents))
    in
    Message.to_bytes { Message.seq = !count; content = summary }
  ;;
end

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let echo_bidi request_stream =
    let response_stream = Grpc_eio.Stream.create 16 in
    (* Run bidi processing in a fiber so handler returns immediately. *)
    Eio.Fiber.fork ~sw (fun () ->
      let rec process () =
        match Grpc_eio.Stream.take request_stream with
        | bytes ->
          let msg = Message.of_bytes bytes in
          let response = { msg with content = "Bidi echo: " ^ msg.content } in
          Grpc_eio.Stream.add response_stream (Message.to_bytes response);
          process ()
        | exception End_of_file -> Grpc_eio.Stream.close response_stream
      in
      process ());
    response_stream
  in
  (* Create service with all 4 RPC types *)
  let echo_service =
    Grpc_eio.Service.create "streaming.Echo"
    |> Grpc_eio.Service.add_unary "Echo" EchoService.echo
    |> Grpc_eio.Service.add_server_streaming "EchoExpand" EchoService.echo_expand
    |> Grpc_eio.Service.add_client_streaming "EchoCollect" EchoService.echo_collect
    |> Grpc_eio.Service.add_bidi_streaming "EchoBidi" echo_bidi
  in
  (* Create server with logging and stream interceptors *)
  let server =
    Grpc_eio.Server.create ()
    |> Grpc_eio.Server.add_service echo_service
    |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
  in
  Printf.printf "🚀 Streaming Echo server starting on port 50051...\n%!";
  Printf.printf "   Methods:\n%!";
  Printf.printf "   - Echo (Unary)\n%!";
  Printf.printf "   - EchoExpand (Server Streaming)\n%!";
  Printf.printf "   - EchoCollect (Client Streaming)\n%!";
  Printf.printf "   - EchoBidi (Bidirectional)\n%!";
  Grpc_eio.Server.serve ~sw ~env server
;;
