(** Model Inference Client - Production client with retry

    Run with: dune exec examples/model-server/inference_client.exe

    This demonstrates:
    - Health check before inference
    - Retry with exponential backoff
    - Timeout handling
    - Production client patterns
*)

(** Request builder *)
module InferRequest = struct
  let create ?(params = []) input =
    let param_str =
      List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) params |> String.concat "|"
    in
    if param_str = "" then input else Printf.sprintf "%s|%s" input param_str
  ;;
end

(** Response parser *)
module InferResponse = struct
  type t =
    { output : string
    ; latency_ms : float
    ; model_version : string
    }

  let of_bytes bytes =
    let parts = String.split_on_char '|' bytes in
    match parts with
    | output :: rest ->
      let latency_ms =
        List.find_map
          (fun s ->
             if String.length s > 8 && String.sub s 0 8 = "latency:"
             then Some (float_of_string (String.sub s 8 (String.length s - 8)))
             else None)
          rest
        |> Option.value ~default:0.0
      in
      let model_version =
        List.find_map
          (fun s ->
             if String.length s > 8 && String.sub s 0 8 = "version:"
             then Some (String.sub s 8 (String.length s - 8))
             else None)
          rest
        |> Option.value ~default:"unknown"
      in
      { output; latency_ms; model_version }
    | _ -> { output = bytes; latency_ms = 0.0; model_version = "unknown" }
  ;;
end

(** Decode protobuf HealthCheckResponse.
    Format: field_tag (1 byte) + status_varint (1 byte)
    - status 0 = UNKNOWN
    - status 1 = SERVING
    - status 2 = NOT_SERVING
    - status 3 = SERVICE_UNKNOWN *)
let decode_health_response bytes =
  if String.length bytes >= 2
  then (
    let tag = Char.code bytes.[0] in
    let field_num = tag lsr 3 in
    if field_num = 1
    then (
      let status = Char.code bytes.[1] in
      match status with
      | 1 -> Some "SERVING"
      | 2 -> Some "NOT_SERVING"
      | 3 -> Some "SERVICE_UNKNOWN"
      | _ -> Some "UNKNOWN")
    else None)
  else None
;;

(** Check server health before making requests *)
let check_health client ~sw ~env =
  Printf.printf "🏥 Checking server health...\n%!";
  match
    Grpc_eio.Client.call_unary
      ~sw
      ~env
      client
      ~service:"grpc.health.v1.Health"
      ~method_:"Check"
      ~request:""
  with
  | Ok response ->
    (match decode_health_response response with
     | Some "SERVING" ->
       Printf.printf "   ✅ Server is healthy (SERVING)\n%!";
       true
     | Some status ->
       Printf.printf "   ⚠️  Server not ready: %s\n%!" status;
       false
     | None ->
       Printf.printf "   ⚠️  Invalid health response format\n%!";
       false)
  | Error status ->
    Printf.printf "   ❌ Health check failed: %s\n%!" status.Grpc_core.Status.message;
    false
;;

(** Make inference request with retry *)
let infer_with_retry client ~sw ~env ~max_retries input =
  let rec attempt n =
    if n > max_retries
    then Error "Max retries exceeded"
    else (
      if n > 0
      then (
        let delay = Float.pow 2.0 (float_of_int (n - 1)) *. 0.1 in
        Printf.printf "   ⏳ Retry %d/%d (waiting %.1fs)...\n%!" n max_retries delay;
        Unix.sleepf delay);
      let request =
        InferRequest.create ~params:[ "temperature", "0.7"; "max_tokens", "100" ] input
      in
      match
        Grpc_eio.Client.call_unary
          ~sw
          ~env
          client
          ~service:"ml.InferenceService"
          ~method_:"Predict"
          ~request
      with
      | Ok response_bytes -> Ok (InferResponse.of_bytes response_bytes)
      | Error status when Grpc_core.Status.(status.code = Unavailable) ->
        (* Retry on transient errors *)
        attempt (n + 1)
      | Error status -> Error status.Grpc_core.Status.message)
  in
  attempt 0
;;

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Printf.printf "🔮 Model Inference Client\n%!";
  Printf.printf "─────────────────────────────────────────\n%!";
  (* Configure retry policy using library's Retry module *)
  let retry_policy =
    Grpc_eio.Retry.
      { default_policy with
        max_attempts = 3
      ; initial_backoff = 0.1
      ; retryable_codes =
          [ Grpc_core.Status.Unavailable; Grpc_core.Status.Resource_exhausted ]
      }
  in
  (* Connect with timeout and retry interceptor *)
  let config =
    Grpc_eio.Client.
      { (default_config ~target:"http://127.0.0.1:50051") with timeout = Some 10.0 }
  in
  let client =
    Grpc_eio.Client.connect ~config ~sw ~env "http://127.0.0.1:50051"
    |> Grpc_eio.Client.with_interceptor
         (Grpc_eio.Retry.interceptor ~policy:retry_policy ())
  in
  Printf.printf "📡 Connected to inference server (with retry policy)\n\n%!";
  (* Health check first *)
  if not (check_health client ~sw ~env)
  then (
    Printf.printf "❌ Server not healthy, exiting\n%!";
    exit 1);
  Printf.printf "\n%!";
  (* Sample inference requests *)
  let inputs =
    [ "Classify this text: OCaml is great"
    ; "Summarize: gRPC enables efficient communication"
    ; "Translate to French: Hello world"
    ]
  in
  List.iteri
    (fun i input ->
       Printf.printf "📤 Request %d: %s\n%!" (i + 1) input;
       match infer_with_retry client ~sw ~env ~max_retries:3 input with
       | Ok response ->
         Printf.printf "   ✅ Output: %s\n" response.output;
         Printf.printf "   ⏱️  Latency: %.2fms\n" response.latency_ms;
         Printf.printf "   📦 Model: %s\n\n" response.model_version
       | Error msg -> Printf.printf "   ❌ Failed: %s\n\n%!" msg)
    inputs;
  Grpc_eio.Client.close client;
  Printf.printf "✅ All requests completed\n%!"
;;
