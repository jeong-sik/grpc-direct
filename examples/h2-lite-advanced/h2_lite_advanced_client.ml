open H2_lite

let host = ref "127.0.0.1"
let port = ref 50051

let () =
  let usage = "H2_lite advanced client (push + priority)" in
  Arg.parse [
    ("-h", Arg.Set_string host, "Host (default 127.0.0.1)");
    ("-p", Arg.Set_int port, "Port (default 50051)");
  ] (fun _ -> ()) usage;

  let on_push (push : H2_lite.push_response) =
    let body, _ = Grpc_message.decode push.response_body in
    Eio.traceln "PUSH stream=%ld body=%s" push.promised_stream_id (Cstruct.to_string body)
  in

  Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
      let client = H2_lite.Client.connect
          ~enable_push:true
          ~priority_scheduling:true
          ~on_push
          ~sw
          ~env
          ~host:!host
          ~port:!port
          ()
      in

      let stream =
        H2_lite.open_stream
          ~is_client:true
          ~hpack_encoder:client.hpack_encoder
          ~hpack_decoder:client.hpack_decoder
          ~flow_control:client.flow_control
          client.conn
      in

      let prio : Frame.priority_info = {
        exclusive = false;
        dependency = 0l;
        weight = 220;
      } in
      H2_lite.send_priority stream prio;

      let path = "/demo.Echo/Unary" in
      let headers = [
        (":method", "POST");
        (":scheme", client.scheme);
        (":path", path);
        (":authority", client.authority);
        ("content-type", "application/grpc+proto");
        ("te", "trailers");
      ] in

      H2_lite.send_headers stream ~end_stream:false headers;
      let body = Grpc_message.encode (Cstruct.of_string "hello") in
      H2_lite.send_data stream ~end_stream:true body;

      let response_buffer = Buffer.create 4096 in
      let status_code = ref None in
      let status_message = ref None in

      let record_status headers =
        match List.assoc_opt "grpc-status" headers with
        | Some s -> status_code := Some s
        | None -> ();
        match List.assoc_opt "grpc-message" headers with
        | Some m -> status_message := Some (H2_lite.percent_decode m)
        | None -> ()
      in

      let rec read_response () =
        let frame = H2_lite.recv_frame ?on_push:client.on_push stream in
        let end_stream = Frame.Flags.is_set frame.Frame.header.flags Frame.Flags.end_stream in
        (match frame.Frame.header.frame_type with
         | Frame.Headers ->
             let headers = decode_headers stream frame in
             record_status headers
         | Frame.Data ->
             Buffer.add_string response_buffer (Cstruct.to_string frame.payload)
         | Frame.RstStream ->
             failwith "Received RST_STREAM from server"
         | _ -> ());
        if not end_stream then read_response ()
      in
      read_response ();

      match !status_code with
      | Some "0" ->
          let resp_body, _ = Grpc_message.decode
              (Cstruct.of_string (Buffer.contents response_buffer)) in
          Eio.traceln "OK: %s" (Cstruct.to_string resp_body)
      | Some code ->
          let msg = Option.value ~default:"Unknown error" !status_message in
          Eio.traceln "gRPC error: %s (%s)" code msg
      | None ->
          Eio.traceln "Missing grpc-status"
