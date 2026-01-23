(** Example gRPC Client demonstrating all 4 RPC types.

    Run with: dune exec examples/streaming/streaming_client.exe

    Requires streaming_server.exe to be running.

    This demonstrates:
    - call_unary: Single request, single response
    - call_server_streaming: Single request, stream of responses
    - call_client_streaming: Stream of requests, single response
    - call_bidi: Stream of requests, stream of responses *)

(** Simple message type *)
module Message = struct
  type t = { content : string; seq : int }

  let of_bytes bytes =
    match String.split_on_char ':' bytes with
    | [seq_str; content] ->
        { seq = int_of_string seq_str; content }
    | _ ->
        { seq = 0; content = bytes }

  let to_bytes t =
    Printf.sprintf "%d:%s" t.seq t.content
end

let test_unary ~sw ~env client =
  Printf.printf "\n=== Testing Unary RPC ===\n%!";
  let request = Message.{ seq = 1; content = "Hello, Unary!" } in
  match Grpc_eio.Client.call_unary ~sw ~env client
    ~service:"streaming.Echo"
    ~method_:"Echo"
    ~request:(Message.to_bytes request)
  with
  | Ok response ->
      let msg = Message.of_bytes response in
      Printf.printf "✅ Response: %s (seq=%d)\n%!" msg.content msg.seq
  | Error status ->
      Printf.printf "❌ Error: %s\n%!" status.Grpc_core.Status.message

let test_server_streaming ~sw ~env client =
  Printf.printf "\n=== Testing Server Streaming RPC ===\n%!";
  (* Request 5 responses *)
  let request = Message.{ seq = 5; content = "Expand me!" } in
  let stream = Grpc_eio.Client.call_server_streaming ~sw ~env client
    ~service:"streaming.Echo"
    ~method_:"EchoExpand"
    ~request:(Message.to_bytes request)
  in
  let rec read_all count =
    match Grpc_eio.Stream.take stream with
    | Ok response ->
        let msg = Message.of_bytes response in
        Printf.printf "  📥 [%d] %s\n%!" msg.seq msg.content;
        read_all (count + 1)
    | Error status ->
        if status.Grpc_core.Status.code = Grpc_core.Status.OK then
          Printf.printf "✅ Stream complete: %d messages\n%!" count
        else
          Printf.printf "❌ Stream error: %s\n%!" status.message
    | exception End_of_file ->
        Printf.printf "✅ Stream ended: %d messages\n%!" count
  in
  read_all 0

let test_client_streaming ~sw ~env client =
  Printf.printf "\n=== Testing Client Streaming RPC ===\n%!";
  let requests = Grpc_eio.Stream.create 16 in

  (* Add messages to the request stream *)
  for i = 1 to 3 do
    let msg = Message.{ seq = i; content = Printf.sprintf "Message %d" i } in
    Printf.printf "  📤 Sending: %s\n%!" msg.content;
    Grpc_eio.Stream.add requests (Message.to_bytes msg)
  done;
  Grpc_eio.Stream.close requests;

  match Grpc_eio.Client.call_client_streaming ~sw ~env client
    ~service:"streaming.Echo"
    ~method_:"EchoCollect"
    ~requests
  with
  | Ok response ->
      let msg = Message.of_bytes response in
      Printf.printf "✅ Response: %s\n%!" msg.content
  | Error status ->
      Printf.printf "❌ Error: %s\n%!" status.Grpc_core.Status.message

type take_result =
  | Msg of (string, Grpc_core.Status.t) result
  | Timeout
  | Eof

let take_with_timeout ~clock ~timeout stream =
  try
    Msg (Eio.Time.with_timeout_exn clock timeout (fun () ->
      Grpc_eio.Stream.take stream))
  with
  | Eio.Time.Timeout -> Timeout
  | End_of_file -> Eof

let test_bidi_streaming ~sw ~env ~clock client =
  Printf.printf "\n=== Testing Bidirectional Streaming RPC ===\n%!";
  let requests = Grpc_eio.Stream.create 16 in

  (* Add messages to the request stream *)
  for i = 1 to 3 do
    let msg = Message.{ seq = i; content = Printf.sprintf "Bidi %d" i } in
    Printf.printf "  📤 Sending: %s\n%!" msg.content;
    Grpc_eio.Stream.add requests (Message.to_bytes msg)
  done;
  Grpc_eio.Stream.close requests;

  let responses = Grpc_eio.Client.call_bidi ~sw ~env client
    ~service:"streaming.Echo"
    ~method_:"EchoBidi"
    ~requests
  in

  let expected = 3 in
  let rec read_all count =
    if count >= expected then
      Printf.printf "✅ Bidi received %d/%d messages\n%!" count expected
    else
      match take_with_timeout ~clock ~timeout:2.0 responses with
      | Msg (Ok response) ->
          let msg = Message.of_bytes response in
          Printf.printf "  📥 [%d] %s\n%!" msg.seq msg.content;
          read_all (count + 1)
      | Msg (Error status) ->
          if status.Grpc_core.Status.code = Grpc_core.Status.OK then
            Printf.printf "✅ Bidi stream complete: %d messages\n%!" count
          else
            Printf.printf "❌ Stream error: %s\n%!" status.message
      | Timeout ->
          Printf.printf "⏱️  Bidi response timeout; stopping after %d/%d\n%!" count expected
      | Eof ->
          Printf.printf "✅ Bidi stream ended: %d messages\n%!" count
  in
  read_all 0;
  Grpc_eio.Stream.close responses

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in

  Printf.printf "📡 Connecting to streaming server at localhost:50051...\n%!";
  let client = Grpc_eio.Client.connect ~sw ~env "http://127.0.0.1:50051" in
  Printf.printf "✅ Connected!\n%!";

  (* Test all 4 RPC types *)
  test_unary ~sw ~env client;
  test_server_streaming ~sw ~env client;
  test_client_streaming ~sw ~env client;
  test_bidi_streaming ~sw ~env ~clock client;

  Printf.printf "\n🎉 All streaming tests complete!\n%!";

  Grpc_eio.Client.close client;
  (* Ensure the example exits even if background fibers remain. *)
  Stdlib.exit 0
