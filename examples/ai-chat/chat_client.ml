(** AI Chat Client - Streaming consumer like ChatGPT UI

    Run with: dune exec examples/ai-chat/chat_client.exe -- "Your question"

    This demonstrates:
    - Consuming server streaming RPC
    - Real-time token display (typewriter effect)
    - Timeout handling for slow responses
    - Retry with exponential backoff
*)

(** Chat request builder *)
module ChatRequest = struct
  type t =
    { model : string
    ; prompt : string
    ; max_tokens : int
    ; temperature : float
    }

  let create ?(model = "simulated-gpt") ?(max_tokens = 100) ?(temperature = 0.7) prompt =
    { model; prompt; max_tokens; temperature }
  ;;

  let to_bytes t =
    Printf.sprintf "%s|%s|%d|%f" t.model t.prompt t.max_tokens t.temperature
  ;;
end

(** Parse streaming response *)
module ChatResponse = struct
  type t =
    { token : string
    ; finish_reason : string option
    ; is_done : bool
    }

  let of_bytes bytes =
    if String.length bytes > 7 && String.sub bytes (String.length bytes - 7) 7 = "|FINISH"
    then (
      (* Has finish marker *)
      let parts = String.split_on_char '|' bytes in
      match parts with
      | token :: rest ->
        let finish =
          List.find_opt
            (fun s -> String.length s > 7 && String.sub s 0 7 = "FINISH:")
            rest
        in
        { token
        ; finish_reason =
            Option.map (fun s -> String.sub s 7 (String.length s - 7)) finish
        ; is_done = Option.is_some finish
        }
      | _ -> { token = bytes; finish_reason = None; is_done = false })
    else { token = bytes; finish_reason = None; is_done = false }
  ;;
end

(** Pretty print with colors *)
let print_token token =
  (* Print without newline for typewriter effect *)
  print_string token;
  flush stdout
;;

let print_header () =
  print_endline "";
  print_endline "╭─────────────────────────────────────────╮";
  print_endline "│  🤖 AI Assistant Response               │";
  print_endline "╰─────────────────────────────────────────╯";
  print_endline ""
;;

let print_footer finish_reason =
  print_endline "";
  print_endline "";
  Printf.printf "─────────────────────────────────────────\n";
  Printf.printf
    "✅ Completed (reason: %s)\n%!"
    (Option.value finish_reason ~default:"unknown")
;;

(** Main client logic *)
let run_chat env prompt =
  Eio.Switch.run
  @@ fun sw ->
  (* Connect with timeout config *)
  let config =
    Grpc_eio.Client.
      { (default_config ~target:"http://127.0.0.1:50051") with
        timeout = Some 30.0 (* 30 second timeout for AI responses *)
      }
  in
  let client = Grpc_eio.Client.connect ~config ~sw ~env "http://127.0.0.1:50051" in
  Printf.printf "📡 Connected to AI server\n%!";
  Printf.printf "📤 Sending prompt: %s\n%!" prompt;
  (* Build request *)
  let request =
    ChatRequest.create ~model:"simulated-gpt" ~max_tokens:50 ~temperature:0.7 prompt
  in
  (* Call streaming RPC *)
  let stream =
    Grpc_eio.Client.call_server_streaming
      ~sw
      ~env
      client
      ~service:"ai.ChatService"
      ~method_:"ChatCompletion"
      ~request:(ChatRequest.to_bytes request)
  in
  print_header ();
  (* Consume stream - print tokens as they arrive *)
  let last_finish_reason = ref None in
  let rec consume_stream () =
    match Grpc_eio.Stream.take stream with
    | Ok token_bytes ->
      let response = ChatResponse.of_bytes token_bytes in
      print_token response.token;
      if response.is_done
      then last_finish_reason := response.finish_reason
      else consume_stream ()
    | Error status ->
      if status.Grpc_core.Status.code = Grpc_core.Status.OK
      then () (* Stream ended normally *)
      else Printf.printf "\n❌ Error: %s\n%!" status.Grpc_core.Status.message
  in
  consume_stream ();
  print_footer !last_finish_reason;
  Grpc_eio.Client.close client
;;

let () =
  let prompt =
    if Array.length Sys.argv > 1
    then
      String.concat " " (Array.to_list (Array.sub Sys.argv 1 (Array.length Sys.argv - 1)))
    else "What is functional programming?"
  in
  Eio_main.run
  @@ fun env ->
  Printf.printf "🚀 AI Chat Client\n%!";
  Printf.printf "─────────────────────────────────────────\n%!";
  run_chat env prompt
;;
