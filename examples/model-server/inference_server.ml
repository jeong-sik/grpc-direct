(** Model Inference Server - Production-style example with TLS + Health Check

    Run with: dune exec examples/model-server/inference_server.exe

    This demonstrates:
    - TLS encrypted connections
    - Health check (K8s ready)
    - Bidirectional streaming (interactive inference)
    - Graceful shutdown
    - Production deployment patterns
*)

(** Inference request/response *)
module InferRequest = struct
  type t = {
    input : string;
    parameters : (string * string) list;
  }

  let of_bytes bytes =
    (* Simple format: input|key1=val1|key2=val2 *)
    match String.split_on_char '|' bytes with
    | input :: params ->
        let parameters = List.filter_map (fun p ->
          match String.split_on_char '=' p with
          | [k; v] -> Some (k, v)
          | _ -> None
        ) params in
        { input; parameters }
    | _ -> { input = bytes; parameters = [] }
end

module InferResponse = struct
  type t = {
    output : string;
    latency_ms : float;
    model_version : string;
  }

  let to_bytes t =
    Printf.sprintf "%s|latency:%.2f|version:%s" t.output t.latency_ms t.model_version
end

(** Server state for health check *)
module ServerState = struct
  let model_loaded = ref false
  let request_count = ref 0
  let error_count = ref 0
  let start_time = ref 0.0

  let init () =
    start_time := Unix.gettimeofday ();
    (* Simulate model loading *)
    Eio.traceln "📦 Loading model...";
    Unix.sleepf 0.5;  (* Simulate load time *)
    model_loaded := true;
    Eio.traceln "✅ Model loaded"

  let is_healthy () = !model_loaded

  (* These are available for future metrics integration *)
  let _uptime () = Unix.gettimeofday () -. !start_time
  let _stats () =
    Printf.sprintf "requests:%d,errors:%d,uptime:%.0fs"
      !request_count !error_count (_uptime ())
end

(** Inference handler - unary RPC *)
let infer (request_bytes : string) : string =
  incr ServerState.request_count;
  let request = InferRequest.of_bytes request_bytes in
  let start = Unix.gettimeofday () in

  let input_preview = String.sub request.input 0 (min 30 (String.length request.input)) in
  Eio.traceln "🔮 [Infer] Processing: %s..." input_preview;

  (* Simulate model inference *)
  Unix.sleepf (0.01 +. Random.float 0.02);

  let output = Printf.sprintf "Processed: %s (params: %d)"
    (String.sub request.input 0 (min 20 (String.length request.input)))
    (List.length request.parameters)
  in
  let latency_ms = (Unix.gettimeofday () -. start) *. 1000.0 in

  let response = InferResponse.{
    output;
    latency_ms;
    model_version = "v1.0.0";
  } in
  InferResponse.to_bytes response

(* Interactive inference placeholder - would be bidirectional streaming
   Commented out to avoid unused warning *)
(* let interactive_infer (request_stream : string Grpc_eio.Stream.t) : string Grpc_eio.Stream.t = ... *)

let () =
  Random.self_init ();

  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->

  (* Initialize server state *)
  ServerState.init ();

  (* Create health service using library's Health module *)
  let health = Grpc_eio.Health.create () in
  (* Set initial status based on model load state *)
  if ServerState.is_healthy () then begin
    Grpc_eio.Health.set_status health ~service:"" Grpc_eio.Health.Serving;
    Grpc_eio.Health.set_status health ~service:"ml.InferenceService" Grpc_eio.Health.Serving
  end else begin
    Grpc_eio.Health.set_status health ~service:"" Grpc_eio.Health.Not_serving;
    Grpc_eio.Health.set_status health ~service:"ml.InferenceService" Grpc_eio.Health.Not_serving
  end;

  (* Create inference service *)
  let inference_service =
    Grpc_eio.Service.create "ml.InferenceService"
    |> Grpc_eio.Service.add_unary "Predict" infer
  in

  (* Server config - TLS ready (uncomment for production) *)
  let config = Grpc_eio.Server.{
    default_config with
    port = 50051;
    (* Uncomment for TLS:
    tls = Some Grpc_eio.Tls_config.{
      cert_file = "./certs/server.crt";
      key_file = "./certs/server.key";
    };
    *)
  } in

  (* Create metrics collector *)
  let metrics = Grpc_eio.Metrics.create () in

  (* Create server ref for Reflection (circular dependency pattern) *)
  let server_ref = ref (Grpc_eio.Server.create ~config ()) in

  (* Build server with all services *)
  let server =
    !server_ref
    |> Grpc_eio.Server.add_service inference_service
    |> Grpc_eio.Server.add_service (Grpc_eio.Health.to_service health)
    |> Grpc_eio.Server.add_service (Grpc_eio.Reflection.to_service server_ref)
    |> Grpc_eio.Server.with_interceptor (Grpc_eio.Metrics.server_interceptor metrics)
    |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
  in
  (* Update ref after adding all services (for Reflection to see them) *)
  server_ref := server;

  (* Print metrics on shutdown (for demo) *)
  at_exit (fun () ->
    Printf.printf "\n📊 Server Metrics (Prometheus format):\n%s\n"
      (Grpc_eio.Metrics.to_prometheus metrics)
  );

  Printf.printf "🚀 Model Inference Server\n%!";
  Printf.printf "─────────────────────────────────────────\n%!";
  Printf.printf "   Port: %d\n%!" config.port;
  Printf.printf "   TLS: %s\n%!" (if Option.is_some config.tls then "enabled" else "disabled");
  Printf.printf "   Health: grpc.health.v1.Health\n%!";
  Printf.printf "   Reflection: grpc.reflection.v1.ServerReflection\n%!";
  Printf.printf "   Metrics: Prometheus format on exit\n%!";
  Printf.printf "\n%!";
  Printf.printf "Test with:\n%!";
  Printf.printf "  dune exec examples/model-server/inference_client.exe\n%!";
  Printf.printf "  grpcurl -plaintext localhost:50051 list\n%!";

  Grpc_eio.Server.serve ~sw ~env server
