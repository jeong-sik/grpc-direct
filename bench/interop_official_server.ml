(* Official gRPC interop TestService server (subset).
   Focuses on core test cases from grpc-go interop client. *)

module Proto = struct
  type payload_type = Compressable

  type payload = {
    payload_type : payload_type;
    body : string;
  }

  type echo_status = {
    code : int;
    message : string;
  }

  type response_parameters = {
    size : int;
    interval_us : int;
  }

  type simple_request = {
    response_type : payload_type;
    response_size : int;
    payload : payload option;
    response_status : echo_status option;
  }

  type streaming_output_request = {
    response_type : payload_type;
    response_parameters : response_parameters list;
    payload : payload option;
    response_status : echo_status option;
  }

  type streaming_input_request = {
    payload : payload option;
  }

  let encode_varint n =
    let buf = Buffer.create 10 in
    let rec loop v =
      if v land lnot 0x7f = 0 then
        Buffer.add_char buf (Char.chr v)
      else begin
        Buffer.add_char buf (Char.chr ((v land 0x7f) lor 0x80));
        loop (v lsr 7)
      end
    in
    loop n;
    Buffer.contents buf

  let decode_varint s off =
    let len = String.length s in
    let rec loop shift acc idx =
      if idx >= len then
        None
      else
        let byte = Char.code s.[idx] in
        let acc = acc lor ((byte land 0x7f) lsl shift) in
        if byte land 0x80 = 0 then
          Some (acc, idx + 1)
        else
          loop (shift + 7) acc (idx + 1)
    in
    loop 0 0 off

  let decode_key s off =
    match decode_varint s off with
    | None -> None
    | Some (key, off1) -> Some (key lsr 3, key land 7, off1)

  let decode_len s off =
    match decode_varint s off with
    | None -> None
    | Some (len, off1) ->
        if off1 + len > String.length s then None
        else Some (String.sub s off1 len, off1 + len)

  let skip_field s wire off =
    match wire with
    | 0 -> decode_varint s off |> Option.map (fun (_v, off1) -> off1)
    | 2 -> decode_len s off |> Option.map (fun (_v, off1) -> off1)
    | 5 ->
        let off1 = off + 4 in
        if off1 <= String.length s then Some off1 else None
    | 1 ->
        let off1 = off + 8 in
        if off1 <= String.length s then Some off1 else None
    | _ -> None

  let payload_type_of_int _ = Compressable
  let payload_type_to_int _ = 0

  let decode_payload bytes =
    let payload_type = ref Compressable in
    let body = ref "" in
    let rec loop off =
      if off >= String.length bytes then ()
      else
        match decode_key bytes off with
        | None -> ()
        | Some (field, wire, off1) ->
            (match field, wire with
             | 1, 0 ->
                 (match decode_varint bytes off1 with
                  | Some (v, off2) ->
                      payload_type := payload_type_of_int v;
                      loop off2
                  | None -> ())
             | 2, 2 ->
                 (match decode_len bytes off1 with
                  | Some (v, off2) ->
                      body := v;
                      loop off2
                  | None -> ())
             | _ ->
                 (match skip_field bytes wire off1 with
                  | Some off2 -> loop off2
                  | None -> ()))
    in
    loop 0;
    { payload_type = !payload_type; body = !body }

  let encode_payload (p : payload) =
    let key_type = encode_varint ((1 lsl 3) lor 0) in
    let key_body = encode_varint ((2 lsl 3) lor 2) in
    let body_len = encode_varint (String.length p.body) in
    key_type ^ encode_varint (payload_type_to_int p.payload_type) ^
    key_body ^ body_len ^ p.body

  let decode_echo_status bytes =
    let code = ref 0 in
    let message = ref "" in
    let rec loop off =
      if off >= String.length bytes then ()
      else
        match decode_key bytes off with
        | None -> ()
        | Some (field, wire, off1) ->
            (match field, wire with
             | 1, 0 ->
                 (match decode_varint bytes off1 with
                  | Some (v, off2) ->
                      code := v;
                      loop off2
                  | None -> ())
             | 2, 2 ->
                 (match decode_len bytes off1 with
                  | Some (v, off2) ->
                      message := v;
                      loop off2
                  | None -> ())
             | _ ->
                 (match skip_field bytes wire off1 with
                  | Some off2 -> loop off2
                  | None -> ()))
    in
    loop 0;
    { code = !code; message = !message }

  let decode_response_parameters bytes =
    let size = ref 0 in
    let interval_us = ref 0 in
    let rec loop off =
      if off >= String.length bytes then ()
      else
        match decode_key bytes off with
        | None -> ()
        | Some (field, wire, off1) ->
            (match field, wire with
             | 1, 0 ->
                 (match decode_varint bytes off1 with
                  | Some (v, off2) ->
                      size := v;
                      loop off2
                  | None -> ())
             | 2, 0 ->
                 (match decode_varint bytes off1 with
                  | Some (v, off2) ->
                      interval_us := v;
                      loop off2
                  | None -> ())
             | _ ->
                 (match skip_field bytes wire off1 with
                  | Some off2 -> loop off2
                  | None -> ()))
    in
    loop 0;
    { size = !size; interval_us = !interval_us }

  let decode_simple_request bytes =
    let response_type = ref Compressable in
    let response_size = ref 0 in
    let payload = ref None in
    let response_status = ref None in
    let rec loop off =
      if off >= String.length bytes then ()
      else
        match decode_key bytes off with
        | None -> ()
        | Some (field, wire, off1) ->
            (match field, wire with
             | 1, 0 ->
                 (match decode_varint bytes off1 with
                  | Some (v, off2) ->
                      response_type := payload_type_of_int v;
                      loop off2
                  | None -> ())
             | 2, 0 ->
                 (match decode_varint bytes off1 with
                  | Some (v, off2) ->
                      response_size := v;
                      loop off2
                  | None -> ())
             | 3, 2 ->
                 (match decode_len bytes off1 with
                  | Some (v, off2) ->
                      payload := Some (decode_payload v);
                      loop off2
                  | None -> ())
             | 7, 2 ->
                 (match decode_len bytes off1 with
                  | Some (v, off2) ->
                      response_status := Some (decode_echo_status v);
                      loop off2
                  | None -> ())
             | _ ->
                 (match skip_field bytes wire off1 with
                  | Some off2 -> loop off2
                  | None -> ()))
    in
    loop 0;
    {
      response_type = !response_type;
      response_size = !response_size;
      payload = !payload;
      response_status = !response_status;
    }

  let decode_streaming_output_request bytes =
    let response_type = ref Compressable in
    let response_parameters = ref [] in
    let payload = ref None in
    let response_status = ref None in
    let rec loop off =
      if off >= String.length bytes then ()
      else
        match decode_key bytes off with
        | None -> ()
        | Some (field, wire, off1) ->
            (match field, wire with
             | 1, 0 ->
                 (match decode_varint bytes off1 with
                  | Some (v, off2) ->
                      response_type := payload_type_of_int v;
                      loop off2
                  | None -> ())
             | 2, 2 ->
                 (match decode_len bytes off1 with
                  | Some (v, off2) ->
                      response_parameters :=
                        decode_response_parameters v :: !response_parameters;
                      loop off2
                  | None -> ())
             | 3, 2 ->
                 (match decode_len bytes off1 with
                  | Some (v, off2) ->
                      payload := Some (decode_payload v);
                      loop off2
                  | None -> ())
             | 7, 2 ->
                 (match decode_len bytes off1 with
                  | Some (v, off2) ->
                      response_status := Some (decode_echo_status v);
                      loop off2
                  | None -> ())
             | _ ->
                 (match skip_field bytes wire off1 with
                  | Some off2 -> loop off2
                  | None -> ()))
    in
    loop 0;
    {
      response_type = !response_type;
      response_parameters = List.rev !response_parameters;
      payload = !payload;
      response_status = !response_status;
    }

  let decode_streaming_input_request bytes =
    let payload = ref None in
    let rec loop off =
      if off >= String.length bytes then ()
      else
        match decode_key bytes off with
        | None -> ()
        | Some (field, wire, off1) ->
            (match field, wire with
             | 1, 2 ->
                 (match decode_len bytes off1 with
                  | Some (v, off2) ->
                      payload := Some (decode_payload v);
                      loop off2
                  | None -> ())
             | _ ->
                 (match skip_field bytes wire off1 with
                  | Some off2 -> loop off2
                  | None -> ()))
    in
    loop 0;
    { payload = !payload }

  let encode_simple_response payload =
    let key = encode_varint ((1 lsl 3) lor 2) in
    let payload_bytes = encode_payload payload in
    key ^ encode_varint (String.length payload_bytes) ^ payload_bytes

  let encode_streaming_output_response payload =
    encode_simple_response payload

  let encode_streaming_input_response aggregated_size =
    let key = encode_varint ((1 lsl 3) lor 0) in
    key ^ encode_varint aggregated_size
end

let make_payload size =
  let body = Bytes.make size 'a' |> Bytes.to_string in
  { Proto.payload_type = Proto.Compressable; body }

let () =
  let host = ref "127.0.0.1" in
  let port = ref 50051 in
  let cert_file = ref "" in
  let key_file = ref "" in
  let ca_file = ref "" in
  let enable_gzip = ref false in
  let usage =
    "interop_official_server --host 127.0.0.1 --port 50051 \
     [--cert cert.pem --key key.pem --ca ca.pem] [--gzip]"
  in
  Arg.parse
    [
      ("--host", Arg.Set_string host, "Bind host");
      ("--port", Arg.Set_int port, "Bind port");
      ("--cert", Arg.Set_string cert_file, "TLS cert file (PEM)");
      ("--key", Arg.Set_string key_file, "TLS key file (PEM)");
      ("--ca", Arg.Set_string ca_file, "CA cert file (PEM) for mTLS");
      ("--gzip", Arg.Set enable_gzip, "Enable gzip compression");
    ]
    (fun _ -> ())
    usage;

  Mirage_crypto_rng_unix.use_default ();

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
    let clock = Eio.Stdenv.clock env in
    let tls =
      if !cert_file = "" || !key_file = "" then
        None
      else if !ca_file = "" then
        Some (Grpc_eio.Tls_config.create ~cert_file:!cert_file ~key_file:!key_file)
      else
        Some (Grpc_eio.Tls_config.create_mtls ~cert_file:!cert_file ~key_file:!key_file ~ca_file:!ca_file)
    in
    let codecs =
      if !enable_gzip then
        [Grpc_core.Codec.identity; Grpc_core.Codec.gzip ()]
      else
        Grpc_eio.Server.default_config.codecs
    in
    let config = { Grpc_eio.Server.default_config with host = !host; port = !port; tls; codecs } in

    let empty_call _bytes = "" in

    let unary_call bytes =
      let req = Proto.decode_simple_request bytes in
      let payload = make_payload req.Proto.response_size in
      Proto.encode_simple_response payload
    in

    let cacheable_unary_call bytes = unary_call bytes in

    let streaming_output_call bytes =
      let req = Proto.decode_streaming_output_request bytes in
      let stream = Grpc_eio.Stream.create (max 1 (List.length req.Proto.response_parameters)) in
      List.iter (fun p ->
        if p.Proto.interval_us > 0 then
          Eio.Time.sleep clock (float_of_int p.Proto.interval_us /. 1_000_000.0);
        let payload = make_payload p.Proto.size in
        Grpc_eio.Stream.add stream (Proto.encode_streaming_output_response payload)
      ) req.Proto.response_parameters;
      Grpc_eio.Stream.close stream;
      stream
    in

    let streaming_input_call request_stream =
      let sum = ref 0 in
      let rec drain () =
        match Grpc_eio.Stream.take request_stream with
        | bytes ->
            let req = Proto.decode_streaming_input_request bytes in
            let size = match req.Proto.payload with
              | None -> 0
              | Some p -> String.length p.Proto.body
            in
            sum := !sum + size;
            drain ()
        | exception End_of_file -> ()
      in
      drain ();
      Proto.encode_streaming_input_response !sum
    in

    let bidi_idle_timeout = 2.0 in
    let full_duplex_call request_stream =
      let response_stream = Grpc_eio.Stream.create 16 in
      Eio.Fiber.fork ~sw (fun () ->
        let rec loop () =
          try
            let bytes =
              Eio.Time.with_timeout_exn clock bidi_idle_timeout (fun () ->
                Grpc_eio.Stream.take request_stream
              )
            in
            let req = Proto.decode_streaming_output_request bytes in
            List.iter (fun p ->
              if p.Proto.interval_us > 0 then
                Eio.Time.sleep clock (float_of_int p.Proto.interval_us /. 1_000_000.0);
              let payload = make_payload p.Proto.size in
              Grpc_eio.Stream.add response_stream (Proto.encode_streaming_output_response payload)
            ) req.Proto.response_parameters;
            loop ()
          with
          | Eio.Time.Timeout ->
              Grpc_eio.Stream.close response_stream
          | End_of_file ->
              Grpc_eio.Stream.close response_stream
        in
        loop ()
      );
      response_stream
    in

    let half_duplex_call request_stream =
      let requests = ref [] in
      let rec drain () =
        match Grpc_eio.Stream.take request_stream with
        | bytes ->
            requests := Proto.decode_streaming_output_request bytes :: !requests;
            drain ()
        | exception End_of_file -> ()
      in
      drain ();
      let stream = Grpc_eio.Stream.create 16 in
      List.iter (fun req ->
        List.iter (fun p ->
          if p.Proto.interval_us > 0 then
            Eio.Time.sleep clock (float_of_int p.Proto.interval_us /. 1_000_000.0);
          let payload = make_payload p.Proto.size in
          Grpc_eio.Stream.add stream (Proto.encode_streaming_output_response payload)
        ) req.Proto.response_parameters
      ) (List.rev !requests);
      Grpc_eio.Stream.close stream;
      stream
    in

    let service =
      Grpc_eio.Service.create "grpc.testing.TestService"
      |> Grpc_eio.Service.add_unary "EmptyCall" empty_call
      |> Grpc_eio.Service.add_unary "UnaryCall" unary_call
      |> Grpc_eio.Service.add_unary "CacheableUnaryCall" cacheable_unary_call
      |> Grpc_eio.Service.add_server_streaming "StreamingOutputCall" streaming_output_call
      |> Grpc_eio.Service.add_client_streaming "StreamingInputCall" streaming_input_call
      |> Grpc_eio.Service.add_bidi_streaming "FullDuplexCall" full_duplex_call
      |> Grpc_eio.Service.add_bidi_streaming "HalfDuplexCall" half_duplex_call
    in

    let server =
      Grpc_eio.Server.create ~config ()
      |> Grpc_eio.Server.add_service service
      |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
    in

    Printf.printf "Official interop server listening on %s:%d\n%!" !host !port;
    Grpc_eio.Server.serve ~sw ~env server
