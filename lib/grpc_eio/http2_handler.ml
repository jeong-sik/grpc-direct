(** HTTP/2 request handling for gRPC.

    Extracted from server.ml for separation of concerns.
    Handles all RPC types: unary, server/client/bidi streaming. *)

open Grpc_core

(** Percent-encode a string for grpc-message header (RFC 3986) *)
let percent_encode s =
  let buf = Buffer.create (String.length s * 3) in
  String.iter
    (fun c ->
       let code = Char.code c in
       if code >= 0x20 && code <= 0x7E && c <> '%'
       then Buffer.add_char buf c
       else Buffer.add_string buf (Printf.sprintf "%%%02X" code))
    s;
  Buffer.contents buf
;;

let deadline_status =
  Grpc_core.Status.
    { code = Deadline_exceeded; message = "Deadline exceeded"; details = None }
;;

let schedule_trailers_safe ~reqd trailers =
  let open H2 in
  try Reqd.schedule_trailers reqd trailers with
  | Failure msg when String.starts_with ~prefix:"h2.Reqd.schedule_trailers" msg -> ()
;;

let respond_with_streaming_safe ~reqd response =
  let open H2 in
  try
    Some (Reqd.respond_with_streaming ~flush_headers_immediately:true reqd response)
  with
  | Assert_failure _ -> None
  | Failure msg when String.starts_with ~prefix:"h2.Reqd.respond_with_streaming" msg ->
    None
;;

let schedule_status_trailers ~reqd status =
  let open H2 in
  let trailers =
    [ ( "grpc-status"
      , string_of_int (Grpc_core.Status.code_to_int status.Grpc_core.Status.code) )
    ; "grpc-message", percent_encode status.Grpc_core.Status.message
    ]
  in
  schedule_trailers_safe ~reqd (Headers.of_list trailers)
;;

let start_deadline_timer ~sw ~clock ~timeout ~on_timeout =
  match timeout with
  | None -> ()
  | Some seconds ->
    Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock seconds;
      on_timeout ())
;;

(** Parse gRPC path: /package.Service/Method -> (service_name, method_name) *)
let parse_path (path : string) : (string * string) option =
  match String.split_on_char '/' path with
  | [ ""; service_name; method_name ] -> Some (service_name, method_name)
  | _ -> None
;;

(** Send error response with trailers *)
let send_error ~reqd ~encodings (status : Grpc_core.Status.t) =
  let open H2 in
  let headers =
    Headers.of_list
      [ "content-type", "application/grpc+proto"; "grpc-accept-encoding", encodings ]
  in
  let response = Response.create ~headers `OK in
  match respond_with_streaming_safe ~reqd response with
  | None -> ()
  | Some body ->
    let trailers =
      Headers.of_list
        [ ( "grpc-status"
          , string_of_int (Grpc_core.Status.code_to_int status.Grpc_core.Status.code) )
        ; "grpc-message", percent_encode status.Grpc_core.Status.message
        ]
    in
    schedule_trailers_safe ~reqd trailers;
    Body.Writer.close body
;;

(** Send success response with body and trailers *)
let send_response ~reqd ~encodings ~codec ~body:response_body ~trailers =
  let open H2 in
  let base_headers =
    [ "content-type", "application/grpc+proto"; "grpc-accept-encoding", encodings ]
  in
  let headers =
    if Codec.is_identity codec
    then Headers.of_list base_headers
    else Headers.of_list (("grpc-encoding", codec.Codec.name) :: base_headers)
  in
  let response = Response.create ~headers `OK in
  match respond_with_streaming_safe ~reqd response with
  | None -> ()
  | Some body ->
    Body.Writer.write_string body response_body;
    schedule_trailers_safe ~reqd (Headers.of_list trailers);
    Body.Writer.flush body (function
      | `Written -> Body.Writer.close body
      | `Closed -> ())
;;

(** Handle server streaming RPC *)
let handle_server_streaming
      ~sw
      ~clock
      ~timeout
      ~reqd
      ~response_codec
      ~handler
      ~request_data
      ~encodings
      ~method_:_
      ~metrics:_
  =
  let open H2 in
  let base_headers =
    [ "content-type", "application/grpc+proto"; "grpc-accept-encoding", encodings ]
  in
  let headers =
    if Codec.is_identity response_codec
    then Headers.of_list base_headers
    else Headers.of_list (("grpc-encoding", response_codec.Codec.name) :: base_headers)
  in
  let response = Response.create ~headers `OK in
  let body_writer = respond_with_streaming_safe ~reqd response in
  let finished = ref false in
  let done_promise, done_resolver = Eio.Promise.create () in
  let body_writer_opt =
    match body_writer with
    | None ->
      finished := true;
      Eio.Promise.resolve done_resolver ();
      None
    | Some bw -> Some bw
  in
  let finish_ok () =
    if not !finished
    then (
      finished := true;
      schedule_trailers_safe ~reqd (Headers.of_list [ "grpc-status", "0" ]);
      Option.iter Body.Writer.close body_writer_opt;
      Eio.Promise.resolve done_resolver ())
  in
  let finish_error (status : Grpc_core.Status.t) =
    if not !finished
    then (
      finished := true;
      schedule_status_trailers ~reqd status;
      Option.iter Body.Writer.close body_writer_opt;
      Eio.Promise.resolve done_resolver ())
  in
  let on_timeout () = finish_error deadline_status in
  start_deadline_timer ~sw ~clock ~timeout ~on_timeout;
  let response_stream = handler request_data in
  let rec write_responses () =
    if !finished
    then ()
    else (
      try
        match
          Eio.Fiber.first
            (fun () -> `Msg (Grpc_stream.take response_stream))
            (fun () ->
               Eio.Promise.await done_promise;
               `Done)
        with
        | `Msg msg ->
          (match Message.encode ~codec:response_codec msg with
           | Ok encoded ->
             (match body_writer_opt with
              | None -> finish_ok ()
              | Some bw ->
                Body.Writer.write_string bw encoded;
                Body.Writer.flush bw (function
                  | `Written -> write_responses ()
                  | `Closed -> finish_ok ()))
           | Error e ->
             finish_error
               Grpc_core.Status.{ code = Internal; message = e; details = None })
        | `Done -> ()
      with
      | End_of_file -> finish_ok ())
  in
  write_responses ()
;;

(** Handle client streaming RPC *)
let handle_client_streaming
      ~sw
      ~clock
      ~timeout
      ~reqd
      ~request_codec
      ~response_codec
      ~handler
      ~encodings
      ~method_:_
      ~metrics:_
  =
  let open H2 in
  let request_stream = Grpc_stream.create 64 in
  let body = Reqd.request_body reqd in
  let buffer = ref "" in
  let finished = ref false in
  let respond_once f =
    if not !finished
    then (
      finished := true;
      f ())
  in
  let on_timeout () =
    respond_once (fun () ->
      Body.Reader.close body;
      send_error ~reqd ~encodings deadline_status)
  in
  start_deadline_timer ~sw ~clock ~timeout ~on_timeout;
  let handle_extract_error err =
    let status =
      match err with
      | Message.Oversized len ->
        Grpc_core.Status.
          { code = Resource_exhausted
          ; message = Printf.sprintf "Message too large: %d bytes" len
          ; details = None
          }
      | Message.Decode_error msg ->
        Grpc_core.Status.{ code = Internal; message = msg; details = None }
    in
    respond_once (fun () -> send_error ~reqd ~encodings status)
  in
  let rec read_messages () =
    if !finished
    then ()
    else
      Body.Reader.schedule_read
        body
        ~on_eof:(fun () ->
          if not !finished
          then (
            match Message.extract_all ~codec:request_codec !buffer with
            | Error err -> handle_extract_error err
            | Ok (messages, _) ->
              List.iter (fun msg -> Grpc_stream.add request_stream msg) messages;
              Grpc_stream.close request_stream;
              let response = handler request_stream in
              respond_once (fun () ->
                match Message.encode ~codec:response_codec response with
                | Ok encoded ->
                  send_response
                    ~reqd
                    ~encodings
                    ~codec:response_codec
                    ~body:encoded
                    ~trailers:[ "grpc-status", "0" ]
                | Error e ->
                  send_error
                    ~reqd
                    ~encodings
                    Grpc_core.Status.{ code = Internal; message = e; details = None })))
        ~on_read:(fun bs ~off ~len ->
          if not !finished
          then (
            let chunk = Bigstringaf.substring bs ~off ~len in
            buffer := !buffer ^ chunk;
            match Message.extract_all ~codec:request_codec !buffer with
            | Error err -> handle_extract_error err
            | Ok (messages, remaining) ->
              buffer := remaining;
              List.iter (fun msg -> Grpc_stream.add request_stream msg) messages;
              read_messages ()))
  in
  read_messages ()
;;

(** Handle bidirectional streaming RPC.

    Writer fiber blocks on response stream and exits on End_of_file.
    Request end signals handler via request_stream close; we then wait
    for response stream completion before closing trailers. *)
let handle_bidi_streaming
      ~sw
      ~clock
      ~timeout
      ~reqd
      ~request_codec
      ~response_codec
      ~handler
      ~encodings
      ~method_:_
      ~metrics:_
  =
  let open H2 in
  let request_stream = Grpc_stream.create 64 in
  let body = Reqd.request_body reqd in
  let buffer = ref "" in
  let response_started = ref false in
  let body_writer = ref None in
  let finished = ref false in
  (* Promise for response_stream - handler runs in fiber to avoid blocking *)
  let response_stream_promise, response_stream_resolver = Eio.Promise.create () in
  (* Promise for writer fiber to signal drain completion *)
  let writer_done_promise, writer_done_resolver = Eio.Promise.create () in
  let signal_writer_done () =
    if not (Eio.Promise.is_resolved writer_done_promise)
    then Eio.Promise.resolve writer_done_resolver ()
  in
  let finish_with_status status =
    if not !finished
    then (
      finished := true;
      Body.Reader.close body;
      Grpc_stream.close request_stream;
      (* Close response_stream if available *)
      (if Eio.Promise.is_resolved response_stream_promise
       then Grpc_stream.close (Eio.Promise.await response_stream_promise));
      Eio.Promise.await writer_done_promise;
      if !response_started
      then (
        schedule_status_trailers ~reqd status;
        Option.iter Body.Writer.close !body_writer)
      else send_error ~reqd ~encodings status)
  in
  let on_timeout () = finish_with_status deadline_status in
  start_deadline_timer ~sw ~clock ~timeout ~on_timeout;
  let ensure_response_started () =
    if not !response_started
    then (
      response_started := true;
      let base_headers =
        [ "content-type", "application/grpc+proto"; "grpc-accept-encoding", encodings ]
      in
      let headers =
        if Codec.is_identity response_codec
        then Headers.of_list base_headers
        else Headers.of_list (("grpc-encoding", response_codec.Codec.name) :: base_headers)
      in
      let resp = Response.create ~headers `OK in
      match respond_with_streaming_safe ~reqd resp with
      | None ->
        finished := true;
        (if Eio.Promise.is_resolved response_stream_promise
         then Grpc_stream.close (Eio.Promise.await response_stream_promise));
        signal_writer_done ()
      | Some bw -> body_writer := Some bw)
  in
  (* Writer fiber: awaits response_stream from handler, then writes responses *)
  Eio.Fiber.fork ~sw (fun () ->
    let response_stream = Eio.Promise.await response_stream_promise in
    let write_message msg =
      ensure_response_started ();
      match Message.encode ~codec:response_codec msg with
      | Error e ->
        (* Log encoding error but continue - don't crash the stream *)
        Eio.traceln "gRPC encode error: %s" e
      | Ok encoded ->
        (match !body_writer with
         | Some bw ->
           Body.Writer.write_string bw encoded;
           Body.Writer.flush bw (function
             | `Written -> ()
             | `Closed ->
               finished := true;
               Grpc_stream.close response_stream;
               signal_writer_done ())
         | None -> ())
    in
    let rec write_responses () =
      if !finished
      then signal_writer_done ()
      else (
        match Grpc_stream.take response_stream with
        | msg ->
          write_message msg;
          write_responses ()
        | exception End_of_file -> signal_writer_done ())
    in
    (* For bidi streaming: send HTTP 200 headers immediately so client
       can start sending request body. Without this, clients wait for
       server headers before continuing, causing deadlock. *)
    Eio.traceln "[BIDI] Writer: calling ensure_response_started";
    ensure_response_started ();
    Eio.traceln "[BIDI] Writer: starting write_responses loop";
    write_responses ());
  (* Handler fiber: create response_stream first, then run handler.
     This allows Writer to start sending HTTP headers immediately,
     which is critical for bidirectional streaming where clients
     wait for server headers before sending request data. *)
  Eio.Fiber.fork ~sw (fun () ->
    let proxy_stream = Grpc_stream.create 64 in
    (* Resolve immediately so Writer can start sending headers *)
    Eio.Promise.resolve response_stream_resolver proxy_stream;
    (* Run handler in nested fiber - it may block on request_stream *)
    Eio.Fiber.fork ~sw (fun () ->
      let handler_stream = handler request_stream in
      (* Copy handler's responses to proxy stream *)
      let rec copy () =
        match Grpc_stream.take handler_stream with
        | msg ->
          Grpc_stream.add proxy_stream msg;
          copy ()
        | exception End_of_file ->
          Grpc_stream.close proxy_stream
      in
      copy ()));
  let handle_extract_error err =
    let status =
      match err with
      | Message.Oversized len ->
        Grpc_core.Status.
          { code = Resource_exhausted
          ; message = Printf.sprintf "Message too large: %d bytes" len
          ; details = None
          }
      | Message.Decode_error msg ->
        Grpc_core.Status.{ code = Internal; message = msg; details = None }
    in
    (* Signal writer to stop, then send error *)
    finish_with_status status
  in
  let rec read_messages () =
    if !finished
    then ()
    else
      Body.Reader.schedule_read
        body
        ~on_eof:(fun () ->
          if not !finished
          then (
            match Message.extract_all ~codec:request_codec !buffer with
            | Error err -> handle_extract_error err
            | Ok (messages, _) ->
              List.iter (fun msg -> Grpc_stream.add request_stream msg) messages;
              Grpc_stream.close request_stream;
              (* Wait for writer fiber to complete drain before closing body.
                 This prevents race condition where body is closed while
                 writer is still flushing buffered messages. *)
              Eio.Promise.await writer_done_promise;
              ensure_response_started ();
              (match !body_writer with
               | Some bw ->
                 schedule_trailers_safe ~reqd (Headers.of_list [ "grpc-status", "0" ]);
                 Body.Writer.close bw
               | None -> ())))
        ~on_read:(fun bs ~off ~len ->
          if not !finished
          then (
            let chunk = Bigstringaf.substring bs ~off ~len in
            buffer := !buffer ^ chunk;
            match Message.extract_all ~codec:request_codec !buffer with
            | Error err -> handle_extract_error err
            | Ok (messages, remaining) ->
              buffer := remaining;
              List.iter (fun msg -> Grpc_stream.add request_stream msg) messages;
              read_messages ()))
  in
  read_messages ()
;;
