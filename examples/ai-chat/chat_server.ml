(** AI Chat Server - Streaming responses like ChatGPT/Claude

    Run with: dune exec examples/ai-chat/chat_server.exe

    This demonstrates:
    - Server streaming RPC (token-by-token responses)
    - Interceptors for logging and metrics
    - Timeout/deadline handling
    - Real-world AI inference pattern
*)

(** Chat message types *)
module ChatRequest = struct
  type t =
    { model : string
    ; prompt : string
    ; max_tokens : int
    ; temperature : float
    }

  let of_bytes bytes =
    (* Simple JSON-like parsing - production would use protobuf *)
    let parts = String.split_on_char '|' bytes in
    match parts with
    | [ model; prompt; max_tokens; temperature ] ->
      { model
      ; prompt
      ; max_tokens = int_of_string max_tokens
      ; temperature = float_of_string temperature
      }
    | _ -> { model = "default"; prompt = bytes; max_tokens = 100; temperature = 0.7 }
  ;;
end

module ChatResponse = struct
  type t =
    { token : string
    ; finish_reason : string option
    }

  let to_bytes t =
    match t.finish_reason with
    | None -> t.token
    | Some reason -> Printf.sprintf "%s|FINISH:%s" t.token reason
  ;;
end

(** Simulated AI model - streams tokens with realistic delays *)
module AIModel = struct
  let generate_response ~prompt ~max_tokens ~temperature:_ =
    (* Simulate AI thinking - in production, call actual model *)
    let responses =
      [ "I"
      ; "'d"
      ; " be"
      ; " happy"
      ; " to"
      ; " help"
      ; " you"
      ; " with"
      ; " that"
      ; "!"
      ; " "
      ; "Based"
      ; " on"
      ; " your"
      ; " question"
      ; " about"
      ; " \""
      ; String.sub prompt 0 (min 20 (String.length prompt))
      ; "\""
      ; ","
      ; " "
      ; "here"
      ; "'s"
      ; " my"
      ; " response"
      ; ":"
      ; " "
      ; "This"
      ; " is"
      ; " a"
      ; " streaming"
      ; " AI"
      ; " response"
      ; "."
      ]
    in
    let tokens =
      if max_tokens < List.length responses
      then List.filteri (fun i _ -> i < max_tokens) responses
      else responses
    in
    tokens
  ;;

  let token_delay () =
    (* Simulate realistic token generation time: 20-80ms *)
    0.02 +. Random.float 0.06
  ;;
end

(** Chat completion handler - streams tokens back *)
let chat_completion (request_bytes : string) : string Grpc_eio.Stream.t =
  let request = ChatRequest.of_bytes request_bytes in
  let stream = Grpc_eio.Stream.create 64 in
  let prompt_preview =
    String.sub request.prompt 0 (min 30 (String.length request.prompt))
  in
  Grpc_eio.Log.info "🤖 [AI] Generating response for: %s..." prompt_preview;
  let tokens =
    AIModel.generate_response
      ~prompt:request.prompt
      ~max_tokens:request.max_tokens
      ~temperature:request.temperature
  in
  (* Stream tokens with realistic delays *)
  List.iteri
    (fun i token ->
       (* Simulate token generation delay *)
       Unix.sleepf (AIModel.token_delay ());
       let is_last = i = List.length tokens - 1 in
       let response =
         ChatResponse.{ token; finish_reason = (if is_last then Some "stop" else None) }
       in
       Grpc_eio.Stream.add stream (ChatResponse.to_bytes response))
    tokens;
  Grpc_eio.Stream.close stream;
  stream
;;

(** Metrics interceptor - tracks request count and latency *)
let metrics_interceptor () : string Grpc_eio.Interceptor.t =
  let request_count = ref 0 in
  Grpc_eio.Interceptor.make ~name:"metrics" (fun ctx next ->
    incr request_count;
    let start = Unix.gettimeofday () in
    let result = next ctx in
    let elapsed = Unix.gettimeofday () -. start in
    Grpc_eio.Log.info "📊 [Metrics] Request #%d completed in %.3fs" !request_count elapsed;
    result)
;;

let () =
  Random.self_init ();
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  (* Create AI chat service *)
  let chat_service =
    Grpc_eio.Service.create "ai.ChatService"
    |> Grpc_eio.Service.add_server_streaming "ChatCompletion" chat_completion
  in
  (* Create server with interceptor chain *)
  let server =
    Grpc_eio.Server.create ()
    |> Grpc_eio.Server.add_service chat_service
    |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
    |> Grpc_eio.Server.with_interceptor (metrics_interceptor ())
  in
  Printf.printf "🤖 AI Chat Server starting on port 50051...\n%!";
  Printf.printf "   Model: simulated-gpt\n%!";
  Printf.printf "   Streaming: enabled\n%!";
  Printf.printf "\n";
  Printf.printf "Test with:\n";
  Printf.printf
    "  dune exec examples/ai-chat/chat_client.exe -- \"Your question here\"\n%!";
  Grpc_eio.Server.serve ~sw ~env server
;;
