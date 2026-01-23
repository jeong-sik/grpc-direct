(** Debug test server - directly use h2 to see what's happening *)

let request_handler _client_addr reqd =
  let open H2 in
  let request = Reqd.request reqd in
  Printf.printf
    "[DEBUG] Request: %s %s\n%!"
    (H2.Method.to_string request.meth)
    request.target;
  Printf.printf "[DEBUG] Headers:\n%!";
  Headers.iter
    ~f:(fun name value -> Printf.printf "  %s: %s\n%!" name value)
    request.headers;
  let content_type =
    Headers.get request.headers "content-type" |> Option.value ~default:""
  in
  if String.starts_with ~prefix:"application/grpc" content_type
  then (
    Printf.printf "[DEBUG] gRPC request detected\n%!";
    let body_parts = ref [] in
    let body = Reqd.request_body reqd in
    let rec read_body () =
      Body.Reader.schedule_read
        body
        ~on_eof:(fun () ->
          let full_body = String.concat "" (List.rev !body_parts) in
          Printf.printf "[DEBUG] Body received: %d bytes\n%!" (String.length full_body);
          (* Send response *)
          let headers = Headers.of_list [ "content-type", "application/grpc+proto" ] in
          let response = Response.create ~headers `OK in
          Printf.printf "[DEBUG] Sending response...\n%!";
          let response_body =
            Reqd.respond_with_streaming ~flush_headers_immediately:true reqd response
          in
          (* Write simple response body - length-prefixed gRPC message *)
          let msg = "{\"echo\":\"test\"}" in
          let len = String.length msg in
          let buf = Bytes.create (5 + len) in
          Bytes.set buf 0 '\x00';
          (* compressed = 0 *)
          Bytes.set buf 1 (Char.chr ((len lsr 24) land 0xff));
          Bytes.set buf 2 (Char.chr ((len lsr 16) land 0xff));
          Bytes.set buf 3 (Char.chr ((len lsr 8) land 0xff));
          Bytes.set buf 4 (Char.chr (len land 0xff));
          Bytes.blit_string msg 0 buf 5 len;
          Body.Writer.write_string response_body (Bytes.to_string buf);
          Printf.printf "[DEBUG] Response body written: %d bytes\n%!" (5 + len);
          (* Schedule trailers *)
          let trailers = Headers.of_list [ "grpc-status", "0"; "grpc-message", "OK" ] in
          Printf.printf "[DEBUG] Scheduling trailers...\n%!";
          Reqd.schedule_trailers reqd trailers;
          Printf.printf "[DEBUG] Closing body...\n%!";
          Body.Writer.close response_body;
          Printf.printf "[DEBUG] Done!\n%!")
        ~on_read:(fun bs ~off ~len ->
          Printf.printf "[DEBUG] Read chunk: %d bytes\n%!" len;
          let chunk = Bigstringaf.substring bs ~off ~len in
          body_parts := chunk :: !body_parts;
          read_body ())
    in
    read_body ())
  else (
    Printf.printf "[DEBUG] Non-gRPC request\n%!";
    let response =
      Response.create ~headers:(Headers.of_list [ "content-type", "text/plain" ]) `OK
    in
    let body =
      Reqd.respond_with_streaming ~flush_headers_immediately:true reqd response
    in
    Body.Writer.write_string body "hello";
    Body.Writer.close body)
;;

let error_handler _client_addr ?request:_ error respond =
  let open H2 in
  let message =
    match error with
    | `Exn exn -> Printexc.to_string exn
    | _ -> "Server error"
  in
  Eio.traceln "%s" message;
  let headers = Headers.of_list [ "content-type", "text/plain" ] in
  let body = respond headers in
  Body.Writer.write_string body message;
  Body.Writer.close body
;;

let () =
  let port = 9940 in
  Printf.printf "Starting DEBUG h2 server on port %d...\n%!" port;
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  let socket = Eio.Net.listen net ~sw ~backlog:128 ~reuse_addr:true addr in
  Printf.printf "Listening on 127.0.0.1:%d\n%!" port;
  let handler = H2_eio.Server.create_connection_handler ~request_handler ~error_handler in
  while true do
    Eio.Net.accept_fork
      socket
      ~sw
      ~on_error:(fun exn -> Eio.traceln "Connection: %s" (Printexc.to_string exn))
      (fun client_socket client_addr -> handler ~sw client_addr client_socket)
  done
;;
