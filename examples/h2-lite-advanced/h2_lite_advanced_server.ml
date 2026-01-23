open H2_lite

let port = ref 50051

let () =
  let usage = "H2_lite advanced server (push + priority)" in
  Arg.parse [ "-p", Arg.Set_int port, "Port (default 50051)" ] (fun _ -> ()) usage;
  Printf.printf "[SERVER] Starting on port %d...\n%!" !port;
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let handler stream (request : Cstruct.t) : Cstruct.t =
    Printf.printf "[SERVER] Handler called, request=%d bytes\n%!" (Cstruct.length request);
    let prio : Frame.priority_info =
      { exclusive = false; dependency = 0l; weight = 200 }
    in
    H2_lite.send_priority stream prio;
    let promised_headers =
      [ ":method", "POST"
      ; ":scheme", "http"
      ; ":path", "/demo.Push/Preload"
      ; ":authority", "localhost"
      ; "content-type", "application/grpc+proto"
      ; "te", "trailers"
      ]
    in
    let promised_stream = H2_lite.send_push_promise stream ~headers:promised_headers in
    let push_body = Grpc_message.encode (Cstruct.of_string "pushed: asset") in
    H2_lite.send_headers
      promised_stream
      ~end_stream:false
      (Hpack.grpc_response_headers ());
    H2_lite.send_data promised_stream ~end_stream:false push_body;
    H2_lite.send_headers promised_stream ~end_stream:true (Hpack.grpc_trailers 0);
    let payload = Cstruct.to_string request in
    Printf.printf "[SERVER] Handler done, returning response\n%!";
    Cstruct.of_string ("echo:" ^ payload)
  in
  H2_lite.Server.serve
    ~enable_push:true
    ~priority_scheduling:false
    ~sw
    ~env
    ~port:!port
    handler
;;
