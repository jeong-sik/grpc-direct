let encode_varint n =
  let buf = Buffer.create 10 in
  let rec loop v =
    if v land lnot 0x7f = 0
    then Buffer.add_char buf (Char.chr v)
    else (
      let byte = v land 0x7f lor 0x80 in
      Buffer.add_char buf (Char.chr byte);
      loop (v lsr 7))
  in
  loop n;
  Buffer.contents buf
;;

let decode_varint s off =
  let len = String.length s in
  let rec loop shift acc idx =
    if idx >= len
    then None
    else (
      let byte = Char.code s.[idx] in
      let acc = acc lor ((byte land 0x7f) lsl shift) in
      if byte land 0x80 = 0 then Some (acc, idx + 1) else loop (shift + 7) acc (idx + 1))
  in
  loop 0 0 off
;;

let encode_payload message =
  let key = (1 lsl 3) lor 2 in
  let len = String.length message in
  encode_varint key ^ encode_varint len ^ message
;;

let decode_payload bytes =
  let len = String.length bytes in
  let rec loop off =
    if off >= len
    then None
    else (
      match decode_varint bytes off with
      | None -> None
      | Some (key, off1) ->
        let field = key lsr 3 in
        let wire = key land 7 in
        (match wire with
         | 2 ->
           (match decode_varint bytes off1 with
            | None -> None
            | Some (l, off2) ->
              if off2 + l > len
              then None
              else if field = 1
              then Some (String.sub bytes off2 l)
              else loop (off2 + l))
         | 0 ->
           (match decode_varint bytes off1 with
            | None -> None
            | Some (_, off2) -> loop off2)
         | _ -> None))
  in
  loop 0
;;

let () =
  let host = ref "127.0.0.1" in
  let port = ref 50051 in
  let cert_file = ref "" in
  let key_file = ref "" in
  let ca_file = ref "" in
  let enable_gzip = ref false in
  let enable_metrics = ref false in
  let metrics_port = ref 9464 in
  let metrics_any = ref false in
  let stream_count = ref 100 in
  let stream_delay = ref 0.0 in
  let shutdown_after = ref 0.0 in
  let usage =
    "interop_streaming_server --host 127.0.0.1 --port 50051 [--cert cert.pem --key \
     key.pem --ca ca.pem] [--gzip] [--metrics] [--metrics-port 9464] [--metrics-any] \
     [--stream-count 100] [--stream-delay 0.0] [--shutdown-after 0]"
  in
  Arg.parse
    [ "--host", Arg.Set_string host, "Bind host"
    ; "--port", Arg.Set_int port, "Bind port"
    ; "--cert", Arg.Set_string cert_file, "TLS cert file (PEM)"
    ; "--key", Arg.Set_string key_file, "TLS key file (PEM)"
    ; "--ca", Arg.Set_string ca_file, "CA cert file (PEM) for mTLS"
    ; "--gzip", Arg.Set enable_gzip, "Enable gzip compression"
    ; "--metrics", Arg.Set enable_metrics, "Enable Prometheus metrics server"
    ; ( "--metrics-port"
      , Arg.Set_int metrics_port
      , "Prometheus metrics port (default: 9464)" )
    ; "--metrics-any", Arg.Set metrics_any, "Bind metrics to 0.0.0.0 (default: loopback)"
    ; "--stream-count", Arg.Set_int stream_count, "Server-streaming response count"
    ; ( "--stream-delay"
      , Arg.Set_float stream_delay
      , "Delay per server-streaming message (seconds)" )
    ; ( "--shutdown-after"
      , Arg.Set_float shutdown_after
      , "Shutdown after N seconds (0 = no)" )
    ]
    (fun _ -> ())
    usage;
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let delay = !stream_delay in
  let sleep_if_needed () = if delay > 0.0 then Eio.Time.sleep clock delay in
  let tls =
    if !cert_file = "" || !key_file = ""
    then None
    else if !ca_file = ""
    then Some (Grpc_eio.Tls_config.create ~cert_file:!cert_file ~key_file:!key_file)
    else
      Some
        (Grpc_eio.Tls_config.create_mtls
           ~cert_file:!cert_file
           ~key_file:!key_file
           ~ca_file:!ca_file)
  in
  let codecs =
    if !enable_gzip
    then [ Grpc_core.Codec.identity; Grpc_core.Codec.gzip () ]
    else Grpc_eio.Server.default_config.codecs
  in
  let config =
    { Grpc_eio.Server.default_config with host = !host; port = !port; tls; codecs }
  in
  let make_stream_response ~count message =
    let capacity = if count <= 0 then 1 else count in
    let stream = Grpc_eio.Stream.create capacity in
    for i = 1 to count do
      let payload = Printf.sprintf "resp-%d:%s" i message in
      sleep_if_needed ();
      Grpc_eio.Stream.add stream (encode_payload payload)
    done;
    Grpc_eio.Stream.close stream;
    stream
  in
  let end_marker = "__END__" in
  let unary_handler bytes =
    let message =
      match decode_payload bytes with
      | Some msg -> msg
      | None -> ""
    in
    encode_payload ("echo:" ^ message)
  in
  let server_stream_handler bytes =
    let message =
      match decode_payload bytes with
      | Some msg -> msg
      | None -> ""
    in
    make_stream_response ~count:!stream_count message
  in
  let client_stream_handler request_stream =
    let count = ref 0 in
    let contents = ref [] in
    let rec drain () =
      match Grpc_eio.Stream.take request_stream with
      | bytes ->
        let msg =
          match decode_payload bytes with
          | Some m -> m
          | None -> ""
        in
        incr count;
        contents := msg :: !contents;
        drain ()
      | exception End_of_file -> ()
    in
    drain ();
    let summary = Printf.sprintf "received %d messages" !count in
    ignore contents;
    encode_payload summary
  in
  let bidi_handler ~sw request_stream =
    let response_stream = Grpc_eio.Stream.create 16 in
    Eio.Fiber.fork ~sw (fun () ->
      let rec loop () =
        let bytes = Grpc_eio.Stream.take request_stream in
        let msg =
          match decode_payload bytes with
          | Some m -> m
          | None -> ""
        in
        if msg = end_marker
        then Grpc_eio.Stream.close response_stream
        else (
          sleep_if_needed ();
          Grpc_eio.Stream.add response_stream (encode_payload ("bidi:" ^ msg));
          loop ())
      in
      try loop () with
      | End_of_file -> Grpc_eio.Stream.close response_stream);
    response_stream
  in
  let service =
    Grpc_eio.Service.create "interop.InteropService"
    |> Grpc_eio.Service.add_unary "Unary" unary_handler
    |> Grpc_eio.Service.add_server_streaming "ServerStream" server_stream_handler
    |> Grpc_eio.Service.add_client_streaming "ClientStream" client_stream_handler
    |> Grpc_eio.Service.add_bidi_streaming "BidiStream" bidi_handler
  in
  let metrics = if !enable_metrics then Some (Grpc_eio.Metrics.create ()) else None in
  let server =
    Grpc_eio.Server.create ~config ()
    |> Grpc_eio.Server.add_service service
    |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
    |>
    match metrics with
    | Some metrics_registry -> Grpc_eio.Server.with_metrics metrics_registry
    | None -> Fun.id
  in
  (match tls with
   | None -> Printf.printf "Interop streaming server listening on %s:%d\n%!" !host !port
   | Some _ ->
     Printf.printf "Interop streaming server (TLS) listening on %s:%d\n%!" !host !port);
  if !shutdown_after > 0.0
  then
    Eio.Fiber.fork ~sw (fun () ->
      let clock = Eio.Stdenv.clock env in
      Eio.Time.sleep clock !shutdown_after;
      Grpc_eio.Server.shutdown server);
  Option.iter
    (fun metrics_registry ->
       let addr =
         if !metrics_any
         then `Tcp (Eio.Net.Ipaddr.V4.any, !metrics_port)
         else `Tcp (Eio.Net.Ipaddr.V4.loopback, !metrics_port)
       in
       Eio.Fiber.fork ~sw (fun () ->
         Grpc_eio.Metrics.serve_prometheus ~addr ~sw ~env metrics_registry);
       Printf.printf
         "Prometheus metrics on %s:%d/metrics\n%!"
         (if !metrics_any then "0.0.0.0" else "127.0.0.1")
         !metrics_port)
    metrics;
  Grpc_eio.Server.serve ~sw ~env server
;;
