(** RPC call implementations: unary, server streaming, client streaming, bidi.

    All four gRPC call patterns are implemented here, sharing a common
    [build_call_headers] helper to eliminate header-construction duplication. *)

open Client_config
open Client_connection

(** Build the standard gRPC call headers shared by all RPC methods.

    Constructs headers with :authority, content-type, te, grpc-accept-encoding,
    optional grpc-encoding (for non-identity codecs), grpc-timeout,
    custom metadata, and call credentials. *)
let build_call_headers
      ~(client : t)
      ~(codec : Grpc_core.Codec.t)
      ~(deadline : float option)
  : H2.Headers.t
  =
  let headers =
    H2.Headers.of_list
      [ ":authority", Printf.sprintf "%s:%d" client.host client.port
      ; "content-type", "application/grpc+proto"
      ; "te", "trailers"
      ; "grpc-accept-encoding", codec.name
      ]
  in
  let headers =
    if Grpc_core.Codec.is_identity codec
    then headers
    else H2.Headers.add headers "grpc-encoding" codec.name
  in
  (* Add grpc-timeout header - per-call deadline overrides config timeout *)
  let effective_timeout =
    match deadline with
    | Some d -> Some d
    | None -> client.config.timeout
  in
  let headers =
    match effective_timeout with
    | None -> headers
    | Some secs ->
      let timeout_ns = Grpc_core.Timeout.of_seconds (int_of_float secs) in
      H2.Headers.add headers "grpc-timeout" (Grpc_core.Timeout.to_string timeout_ns)
  in
  (* Add custom metadata *)
  let headers = add_metadata headers client.config.metadata in
  (* Add call credentials headers (e.g., authorization) *)
  add_metadata headers client.call_credentials_headers
;;

(** Call a unary RPC method.

    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name (e.g., "helloworld.Greeter")
    @param method_ Method name (e.g., "SayHello")
    @param request Request bytes (protobuf-encoded)
    @return Response bytes or error status *)
let call_unary
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(request : string)
  : (string, Grpc_core.Status.t) result
  =
  let net = Eio.Stdenv.net env in
  let path = Printf.sprintf "/%s/%s" service method_ in
  let codec = client.config.codec in
  (* Encode the request with framing - fail early if encoding fails *)
  match Grpc_core.Message.encode ~codec request with
  | Error e ->
    Error
      Grpc_core.Status.
        { code = Internal
        ; message = Printf.sprintf "Request encoding failed: %s" e
        ; details = None
        }
  | Ok framed_request ->
    let headers = build_call_headers ~client ~codec ~deadline in
    (* Get or create cached connection for connection reuse (HTTP/2 multiplexing) *)
    let get_or_create_connection () : (H2.Client_connection.t, Grpc_core.Status.t) result =
      match client.h2_connection with
      | Some conn -> Ok conn
      | None ->
        (* Create new socket and connection *)
        let service = string_of_int client.port in
        let addrs = Eio.Net.getaddrinfo_stream net ~service client.host in
        (match addrs with
         | [] ->
           Error
             Grpc_core.Status.
               { code = Unavailable
               ; message = Printf.sprintf "Cannot resolve: %s:%d" client.host client.port
               ; details = None
               }
         | addr :: _ ->
           let socket = Eio.Net.connect ~sw net addr in
           client.socket <- Some (socket :> Eio.Flow.two_way_ty Eio.Std.r);
           let conn =
             match client.tls_client_config with
             | Some tls_config ->
               let tls_flow = Tls_eio.client_of_flow tls_config socket in
               Flow_handler.create_client_connection
                 ~sw
                 ~error_handler:(fun _ -> ())
                 tls_flow
             | None ->
               let h2_client =
                 H2_eio.Client.create_connection ~sw ~error_handler:(fun _ -> ()) socket
               in
               h2_client.connection
           in
           client.h2_connection <- Some conn;
           Ok conn)
    in
    (match get_or_create_connection () with
     | Error e -> Error e
     | Ok connection ->
       (* Track response using Eio.Promise for proper synchronization *)
       (* Use Buffer for O(1) amortized string concatenation instead of O(n^2) *)
       let response_buffer = Buffer.create 4096 in
       let response_headers = ref H2.Headers.empty in
       let response_trailers = ref H2.Headers.empty in
       let response_promise, response_resolver = Eio.Promise.create () in
       (* Trailers handler - gRPC sends grpc-status in trailers *)
       let trailers_handler trailers = response_trailers := trailers in
       let response_handler (response : H2.Response.t) body =
         response_headers := response.headers;
         let rec read () =
           H2.Body.Reader.schedule_read
             body
             ~on_eof:(fun () ->
               (* Check grpc-status from trailers first, then headers *)
               let get_header name =
                 match H2.Headers.get !response_trailers name with
                 | Some v -> Some v
                 | None -> H2.Headers.get !response_headers name
               in
               let status_code_opt =
                 Option.bind (get_header "grpc-status") int_of_string_opt
               in
               let message =
                 get_header "grpc-message"
                 |> Option.map percent_decode
                 |> Option.value ~default:"Unknown error"
               in
               let details =
                 Option.bind
                   (get_header "grpc-status-details-bin")
                   Metadata.decode_bin_value
               in
               match status_code_opt with
               | Some 0 ->
                 Eio.Promise.resolve
                   response_resolver
                   (Ok (Buffer.contents response_buffer))
               | Some code ->
                 Eio.Promise.resolve
                   response_resolver
                   (Error
                      Grpc_core.Status.
                        { code = Grpc_core.Status.code_of_int code; message; details })
               | None ->
                 let http_code = H2.Status.to_code response.status in
                 let code = map_http_status_code http_code in
                 let msg =
                   Printf.sprintf
                     "missing grpc-status, inferred from HTTP status code %d"
                     http_code
                 in
                 Eio.Promise.resolve
                   response_resolver
                   (Error Grpc_core.Status.{ code; message = msg; details }))
             ~on_read:(fun bs ~off ~len ->
               (* O(1) buffer append instead of O(n) string concat *)
               Buffer.add_string response_buffer (Bigstringaf.substring bs ~off ~len);
               read ())
         in
         read ()
       in
       let _error_handler error =
         let msg =
           match error with
           | `Malformed_response s -> Printf.sprintf "Malformed response: %s" s
           | `Invalid_response_body_length _ -> "Invalid response body length"
           | `Exn exn -> Printexc.to_string exn
           | `Protocol_error (code, msg) ->
             Printf.sprintf "Protocol error %s: %s" (H2.Error_code.to_string code) msg
         in
         Eio.Promise.resolve
           response_resolver
           (Error Grpc_core.Status.{ code = Unavailable; message = msg; details = None })
       in
       (* Send request with trailers handler for gRPC status - using cached connection *)
       let request_body =
         H2.Client_connection.request
           connection
           (H2.Request.create ~scheme:client.scheme ~headers `POST path)
           ~error_handler:(fun _ -> ())
           ~trailers_handler
           ~response_handler
       in
       H2.Body.Writer.write_string request_body framed_request;
       H2.Body.Writer.close request_body;
       (* Wait for response using Eio.Promise (no busy-wait) *)
       let result = Eio.Promise.await response_promise in
       (* Decode the response frame *)
       (match result with
        | Error e -> Error e
        | Ok body ->
          (match Grpc_core.Message.decode ~codec body with
           | Ok decoded -> Ok decoded
           | Error e ->
             Error
               Grpc_core.Status.
                 { code = Internal
                 ; message = Printf.sprintf "Failed to decode response: %s" e
                 ; details = None
                 })))
;;

(** Call a server streaming RPC method.

    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @return A stream of response messages *)
let call_server_streaming
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(request : string)
  : (string, Grpc_core.Status.t) result Grpc_stream.t
  =
  let stream = Grpc_stream.create 16 in
  (* Spawn fiber to handle streaming *)
  Eio.Fiber.fork ~sw (fun () ->
    let net = Eio.Stdenv.net env in
    let path = Printf.sprintf "/%s/%s" service method_ in
    let codec = client.config.codec in
    (* Encode request - if fails, add error to stream and return *)
    let framed_request =
      match Grpc_core.Message.encode ~codec request with
      | Ok f -> f
      | Error e ->
        Grpc_stream.add
          stream
          (Error
             Grpc_core.Status.
               { code = Internal
               ; message = Printf.sprintf "Request encoding failed: %s" e
               ; details = None
               });
        Grpc_stream.close stream;
        (* Exit the fiber early - cannot proceed without encoded request *)
        raise Exit
    in
    let headers = build_call_headers ~client ~codec ~deadline in
    let service = string_of_int client.port in
    let addrs = Eio.Net.getaddrinfo_stream net ~service client.host in
    let socket =
      match addrs with
      | [] ->
        Grpc_stream.add
          stream
          (Error
             Grpc_core.Status.
               { code = Unavailable
               ; message = Printf.sprintf "Cannot resolve: %s:%d" client.host client.port
               ; details = None
               });
        Grpc_stream.close stream;
        raise Exit
      | addr :: _ -> Eio.Net.connect ~sw net addr
    in
    let buffer = ref "" in
    let response_headers = ref H2.Headers.empty in
    let response_trailers = ref H2.Headers.empty in
    let trailers_handler trailers = response_trailers := trailers in
    let response_handler (response : H2.Response.t) body =
      response_headers := response.headers;
      let rec read () =
        H2.Body.Reader.schedule_read
          body
          ~on_eof:(fun () ->
            let get_header name =
              match H2.Headers.get !response_trailers name with
              | Some v -> Some v
              | None -> H2.Headers.get !response_headers name
            in
            let status_code_opt =
              Option.bind (get_header "grpc-status") int_of_string_opt
            in
            let message =
              get_header "grpc-message"
              |> Option.map percent_decode
              |> Option.value ~default:""
            in
            let details =
              Option.bind (get_header "grpc-status-details-bin") Metadata.decode_bin_value
            in
            let status =
              match status_code_opt with
              | Some 0 -> Grpc_core.Status.ok
              | Some code ->
                Grpc_core.Status.
                  { code = Grpc_core.Status.code_of_int code; message; details }
              | None ->
                let http_code = H2.Status.to_code response.status in
                let code = map_http_status_code http_code in
                let msg =
                  Printf.sprintf
                    "missing grpc-status, inferred from HTTP status code %d"
                    http_code
                in
                Grpc_core.Status.{ code; message = msg; details }
            in
            Grpc_stream.add stream (Error status);
            Grpc_stream.close stream)
          ~on_read:(fun bs ~off ~len ->
            let chunk = Bigstringaf.substring bs ~off ~len in
            buffer := !buffer ^ chunk;
            (* Extract complete messages *)
            match Grpc_core.Message.extract_all ~codec !buffer with
            | Error (Grpc_core.Message.Oversized len) ->
              Grpc_stream.add
                stream
                (Error
                   Grpc_core.Status.
                     { code = Resource_exhausted
                     ; message =
                         Printf.sprintf "Server sent oversized message: %d bytes" len
                     ; details = None
                     });
              Grpc_stream.close stream
            | Error (Grpc_core.Message.Decode_error msg) ->
              Grpc_stream.add
                stream
                (Error
                   Grpc_core.Status.
                     { code = Internal
                     ; message = Printf.sprintf "Decode error: %s" msg
                     ; details = None
                     });
              Grpc_stream.close stream
            | Ok (messages, remaining) ->
              buffer := remaining;
              List.iter (fun msg -> Grpc_stream.add stream (Ok msg)) messages;
              read ())
      in
      read ()
    in
    let error_handler _error =
      Grpc_stream.add
        stream
        (Error
           Grpc_core.Status.
             { code = Unavailable; message = "Connection error"; details = None });
      Grpc_stream.close stream
    in
    (* Create HTTP/2 connection - TLS if configured *)
    let connection : H2.Client_connection.t =
      match client.tls_client_config with
      | Some tls_config ->
        let tls_flow = Tls_eio.client_of_flow tls_config socket in
        Flow_handler.create_client_connection ~sw ~error_handler tls_flow
      | None ->
        let h2_client = H2_eio.Client.create_connection ~sw ~error_handler socket in
        h2_client.connection
    in
    let request_body =
      H2.Client_connection.request
        connection
        (H2.Request.create ~scheme:client.scheme ~headers `POST path)
        ~error_handler:(fun _ -> ())
        ~response_handler
        ~trailers_handler
    in
    H2.Body.Writer.write_string request_body framed_request;
    H2.Body.Writer.close request_body);
  stream
;;

(** Call a client streaming RPC method.

    Client sends a stream of requests, server returns a single response.

    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name
    @param method_ Method name
    @param requests Stream of request bytes
    @return Single response or error status *)
let call_client_streaming
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(requests : string Grpc_stream.t)
  : (string, Grpc_core.Status.t) result
  =
  let net = Eio.Stdenv.net env in
  let path = Printf.sprintf "/%s/%s" service method_ in
  let codec = client.config.codec in
  let headers = build_call_headers ~client ~codec ~deadline in
  (* Connect to server *)
  let port_str = string_of_int client.port in
  let addrs = Eio.Net.getaddrinfo_stream net ~service:port_str client.host in
  match addrs with
  | [] ->
    Error
      Grpc_core.Status.
        { code = Unavailable
        ; message = Printf.sprintf "Cannot resolve: %s:%d" client.host client.port
        ; details = None
        }
  | addr :: _ ->
    let socket = Eio.Net.connect ~sw net addr in
    (* Track response - using Buffer for O(1) amortized append *)
    let response_buffer = Buffer.create 4096 in
    let response_headers = ref H2.Headers.empty in
    let response_trailers = ref H2.Headers.empty in
    let response_promise, response_resolver = Eio.Promise.create () in
    let trailers_handler trailers = response_trailers := trailers in
    let response_handler (response : H2.Response.t) body =
      response_headers := response.headers;
      let rec read () =
        H2.Body.Reader.schedule_read
          body
          ~on_eof:(fun () ->
            let get_header name =
              match H2.Headers.get !response_trailers name with
              | Some v -> Some v
              | None -> H2.Headers.get !response_headers name
            in
            let status_code_opt =
              Option.bind (get_header "grpc-status") int_of_string_opt
            in
            let message =
              get_header "grpc-message"
              |> Option.map percent_decode
              |> Option.value ~default:"Unknown error"
            in
            let details =
              Option.bind (get_header "grpc-status-details-bin") Metadata.decode_bin_value
            in
            match status_code_opt with
            | Some 0 ->
              Eio.Promise.resolve response_resolver (Ok (Buffer.contents response_buffer))
            | Some code ->
              Eio.Promise.resolve
                response_resolver
                (Error
                   Grpc_core.Status.
                     { code = Grpc_core.Status.code_of_int code; message; details })
            | None ->
              let http_code = H2.Status.to_code response.status in
              let code = map_http_status_code http_code in
              let msg =
                Printf.sprintf
                  "missing grpc-status, inferred from HTTP status code %d"
                  http_code
              in
              Eio.Promise.resolve
                response_resolver
                (Error Grpc_core.Status.{ code; message = msg; details }))
          ~on_read:(fun bs ~off ~len ->
            Buffer.add_string response_buffer (Bigstringaf.substring bs ~off ~len);
            read ())
      in
      read ()
    in
    let error_handler error =
      let msg =
        match error with
        | `Malformed_response s -> Printf.sprintf "Malformed response: %s" s
        | `Invalid_response_body_length _ -> "Invalid response body length"
        | `Exn exn -> Printexc.to_string exn
        | `Protocol_error (code, msg) ->
          Printf.sprintf "Protocol error %s: %s" (H2.Error_code.to_string code) msg
      in
      Eio.Promise.resolve
        response_resolver
        (Error Grpc_core.Status.{ code = Unavailable; message = msg; details = None })
    in
    (* Create HTTP/2 connection - TLS if configured *)
    let connection : H2.Client_connection.t =
      match client.tls_client_config with
      | Some tls_config ->
        let tls_flow = Tls_eio.client_of_flow tls_config socket in
        Flow_handler.create_client_connection ~sw ~error_handler tls_flow
      | None ->
        let h2_client = H2_eio.Client.create_connection ~sw ~error_handler socket in
        h2_client.connection
    in
    (* Send request with streaming body *)
    let request_body =
      H2.Client_connection.request
        connection
        (H2.Request.create ~scheme:client.scheme ~headers `POST path)
        ~error_handler:(fun _ -> ())
        ~response_handler
        ~trailers_handler
    in
    (* Spawn fiber to write stream of requests *)
    Eio.Fiber.fork ~sw (fun () ->
      let rec write_loop () =
        match Grpc_stream.take requests with
        | req ->
          (match Grpc_core.Message.encode ~codec req with
           | Ok framed -> H2.Body.Writer.write_string request_body framed
           | Error _ -> ());
          (* Skip malformed messages *)
          write_loop ()
        | exception End_of_file -> H2.Body.Writer.close request_body
      in
      write_loop ());
    (* Wait for response *)
    let result = Eio.Promise.await response_promise in
    (* Decode response *)
    (match result with
     | Error e -> Error e
     | Ok body ->
       (match Grpc_core.Message.decode ~codec body with
        | Ok decoded -> Ok decoded
        | Error e ->
          Error
            Grpc_core.Status.
              { code = Internal
              ; message = Printf.sprintf "Failed to decode response: %s" e
              ; details = None
              }))
;;

(** Call a bidirectional streaming RPC method.

    Both client and server can send streams of messages.

    @param deadline Optional per-call deadline in seconds (overrides config timeout)
    @param client The gRPC client
    @param service Service name
    @param method_ Method name
    @param requests Stream of request bytes to send
    @return Stream of response bytes *)
let call_bidi
      ~sw
      ~env
      ?(deadline : float option)
      (client : t)
      ~(service : string)
      ~(method_ : string)
      ~(requests : string Grpc_stream.t)
  : (string, Grpc_core.Status.t) result Grpc_stream.t
  =
  let responses = Grpc_stream.create 16 in
  (* Spawn fiber for bidi communication *)
  Eio.Fiber.fork ~sw (fun () ->
    let net = Eio.Stdenv.net env in
    let path = Printf.sprintf "/%s/%s" service method_ in
    let codec = client.config.codec in
    let headers = build_call_headers ~client ~codec ~deadline in
    (* Connect to server *)
    let port_str = string_of_int client.port in
    let addrs = Eio.Net.getaddrinfo_stream net ~service:port_str client.host in
    let socket =
      match addrs with
      | [] ->
        Grpc_stream.add
          responses
          (Error
             Grpc_core.Status.
               { code = Unavailable
               ; message = Printf.sprintf "Cannot resolve: %s:%d" client.host client.port
               ; details = None
               });
        Grpc_stream.close responses;
        raise Exit
      | addr :: _ -> Eio.Net.connect ~sw net addr
    in
    let buffer = ref "" in
    let response_headers = ref H2.Headers.empty in
    let response_trailers = ref H2.Headers.empty in
    let trailers_handler trailers = response_trailers := trailers in
    let response_handler (response : H2.Response.t) body =
      response_headers := response.headers;
      let rec read () =
        H2.Body.Reader.schedule_read
          body
          ~on_eof:(fun () ->
            let get_header name =
              match H2.Headers.get !response_trailers name with
              | Some v -> Some v
              | None -> H2.Headers.get !response_headers name
            in
            let status_code_opt =
              Option.bind (get_header "grpc-status") int_of_string_opt
            in
            let message =
              get_header "grpc-message"
              |> Option.map percent_decode
              |> Option.value ~default:""
            in
            let details =
              Option.bind (get_header "grpc-status-details-bin") Metadata.decode_bin_value
            in
            let status =
              match status_code_opt with
              | Some 0 -> Grpc_core.Status.ok
              | Some code ->
                Grpc_core.Status.
                  { code = Grpc_core.Status.code_of_int code; message; details }
              | None ->
                let http_code = H2.Status.to_code response.status in
                let code = map_http_status_code http_code in
                let msg =
                  Printf.sprintf
                    "missing grpc-status, inferred from HTTP status code %d"
                    http_code
                in
                Grpc_core.Status.{ code; message = msg; details }
            in
            Grpc_stream.add responses (Error status);
            Grpc_stream.close responses)
          ~on_read:(fun bs ~off ~len ->
            let chunk = Bigstringaf.substring bs ~off ~len in
            buffer := !buffer ^ chunk;
            (* Extract complete messages *)
            match Grpc_core.Message.extract_all ~codec !buffer with
            | Error (Grpc_core.Message.Oversized len) ->
              Grpc_stream.add
                responses
                (Error
                   Grpc_core.Status.
                     { code = Resource_exhausted
                     ; message =
                         Printf.sprintf "Server sent oversized message: %d bytes" len
                     ; details = None
                     });
              Grpc_stream.close responses
            | Error (Grpc_core.Message.Decode_error msg) ->
              Grpc_stream.add
                responses
                (Error
                   Grpc_core.Status.
                     { code = Internal
                     ; message = Printf.sprintf "Decode error: %s" msg
                     ; details = None
                     });
              Grpc_stream.close responses
            | Ok (messages, remaining) ->
              buffer := remaining;
              List.iter (fun msg -> Grpc_stream.add responses (Ok msg)) messages;
              read ())
      in
      read ()
    in
    let error_handler _error =
      Grpc_stream.add
        responses
        (Error
           Grpc_core.Status.
             { code = Unavailable; message = "Connection error"; details = None });
      Grpc_stream.close responses
    in
    (* Create HTTP/2 connection - TLS if configured *)
    let connection : H2.Client_connection.t =
      match client.tls_client_config with
      | Some tls_config ->
        let tls_flow = Tls_eio.client_of_flow tls_config socket in
        Flow_handler.create_client_connection ~sw ~error_handler tls_flow
      | None ->
        let h2_client = H2_eio.Client.create_connection ~sw ~error_handler socket in
        h2_client.connection
    in
    let request_body =
      H2.Client_connection.request
        connection
        (H2.Request.create ~scheme:client.scheme ~headers `POST path)
        ~error_handler:(fun _ -> ())
        ~response_handler
        ~trailers_handler
    in
    (* Write requests in a separate fiber *)
    Eio.Fiber.fork ~sw (fun () ->
      let rec write_loop () =
        match Grpc_stream.take requests with
        | req ->
          (match Grpc_core.Message.encode ~codec req with
           | Ok framed -> H2.Body.Writer.write_string request_body framed
           | Error _ -> ());
          write_loop ()
        | exception End_of_file -> H2.Body.Writer.close request_body
      in
      write_loop ()));
  responses
;;
