(** gRPC-Web client example.

    Run:
      dune exec examples/grpc-web/grpc_web_client.exe
*)

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let client =
    match Grpc_eio.Grpc_web_client.connect ~env "http://127.0.0.1:8080" with
    | Ok c -> c
    | Error status ->
      Printf.eprintf "Connect failed: %s\n%!" (Grpc_core.Status.to_string status);
      exit 1
  in
  let make_stream items =
    let stream = Grpc_eio.Stream.create 8 in
    List.iter (fun item -> Grpc_eio.Stream.add stream item) items;
    Grpc_eio.Stream.close stream;
    stream
  in
  (* Unary call *)
  let unary =
    Grpc_eio.Grpc_web_client.call_unary
      ~sw
      ~env
      client
      ~service:"web.Echo"
      ~method_:"Echo"
      ~request:"1:hello"
  in
  (match unary with
   | Ok resp -> Printf.printf "Unary response: %s\n%!" resp
   | Error status ->
     Printf.printf "Unary error: %s\n%!" (Grpc_core.Status.to_string status));
  (* Server streaming call *)
  let stream =
    Grpc_eio.Grpc_web_client.call_server_streaming
      ~sw
      ~env
      client
      ~service:"web.Echo"
      ~method_:"EchoStream"
      ~request:"1:stream"
  in
  let rec drain () =
    match Grpc_eio.Stream.take stream with
    | Ok msg ->
      Printf.printf "Stream msg: %s\n%!" msg;
      drain ()
    | Error status ->
      Printf.printf "Stream end: %s\n%!" (Grpc_core.Status.to_string status)
  in
  drain ();
  (* Client streaming call (buffered request stream) *)
  let reqs = make_stream [ "1:alpha"; "2:beta"; "3:gamma" ] in
  let collected =
    Grpc_eio.Grpc_web_client.call_client_streaming
      ~sw
      ~env
      client
      ~service:"web.Echo"
      ~method_:"EchoCollect"
      ~requests:reqs
  in
  (match collected with
   | Ok resp -> Printf.printf "Client stream resp: %s\n%!" resp
   | Error status ->
     Printf.printf "Client stream error: %s\n%!" (Grpc_core.Status.to_string status));
  (* Bidi streaming call (buffered request stream) *)
  let bidi_reqs = make_stream [ "1:hi"; "2:there"; "3:bidi" ] in
  let bidi =
    Grpc_eio.Grpc_web_client.call_bidi
      ~sw
      ~env
      client
      ~service:"web.Echo"
      ~method_:"EchoBidi"
      ~requests:bidi_reqs
  in
  let rec drain_bidi () =
    match Grpc_eio.Stream.take bidi with
    | Ok msg ->
      Printf.printf "Bidi msg: %s\n%!" msg;
      drain_bidi ()
    | Error status -> Printf.printf "Bidi end: %s\n%!" (Grpc_core.Status.to_string status)
  in
  drain_bidi ()
;;
