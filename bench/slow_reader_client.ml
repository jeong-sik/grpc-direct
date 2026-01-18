open Printf

let encode_varint n =
  let buf = Buffer.create 10 in
  let rec loop v =
    if v land lnot 0x7f = 0 then
      Buffer.add_char buf (Char.chr v)
    else
      let byte = (v land 0x7f) lor 0x80 in
      Buffer.add_char buf (Char.chr byte);
      loop (v lsr 7)
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

let encode_payload message =
  let key = (1 lsl 3) lor 2 in
  let len = String.length message in
  encode_varint key ^ encode_varint len ^ message

let decode_payload bytes =
  let len = String.length bytes in
  let rec loop off =
    if off >= len then
      None
    else
      match decode_varint bytes off with
      | None -> None
      | Some (key, off1) ->
          let field = key lsr 3 in
          let wire = key land 7 in
          match wire with
          | 2 -> (
              match decode_varint bytes off1 with
              | None -> None
              | Some (l, off2) ->
                  if off2 + l > len then
                    None
                  else if field = 1 then
                    Some (String.sub bytes off2 l)
                  else
                    loop (off2 + l)
            )
          | 0 -> (
              match decode_varint bytes off1 with
              | None -> None
              | Some (_, off2) -> loop off2
            )
          | _ -> None
  in
  loop 0

let target = ref "http://127.0.0.1:50051"
let delay = ref 0.05
let max_messages = ref 100
let message = ref "slow-reader"
let print_every = ref 50

let () =
  let usage = "slow_reader_client [--target url] [--delay s] [--max n]" in
  Arg.parse
    [ ("--target", Arg.Set_string target, "Target URL (default: http://127.0.0.1:50051)");
      ("--delay", Arg.Set_float delay, "Delay between reads in seconds (default: 0.05)");
      ("--max", Arg.Set_int max_messages, "Max messages to read (default: 100)");
      ("--message", Arg.Set_string message, "Payload message string");
      ("--print-every", Arg.Set_int print_every, "Print every N messages (default: 50)")
    ]
    (fun _ -> ())
    usage;

  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run @@ fun sw ->
    let client = Grpc_eio.Client.connect ~sw ~env !target in
    let request = encode_payload !message in
    let stream = Grpc_eio.Client.call_server_streaming ~sw ~env client
      ~service:"interop.InteropService"
      ~method_:"ServerStream"
      ~request
    in
    let rec drain count =
      match Grpc_eio.Stream.take stream with
      | Ok _bytes -> drain count
      | Error status ->
          if status.Grpc_core.Status.code = Grpc_core.Status.OK then
            printf "Stream completed after %d messages\n%!" count
          else
            printf "Stream error (%s) after %d messages\n%!" status.message count
      | exception End_of_file ->
          printf "Stream ended after %d messages\n%!" count
    in
    let rec loop count =
      if count >= !max_messages then begin
        printf "Reached max messages: %d\n%!" count;
        drain count
      end else
        match Grpc_eio.Stream.take stream with
        | Ok bytes ->
            if !print_every > 0 && count mod !print_every = 0 then begin
              let msg = match decode_payload bytes with
                | Some v -> v
                | None -> ""
              in
              printf "recv[%d]: %s\n%!" count msg
            end;
            if !delay > 0.0 then
              Eio.Time.sleep clock !delay;
            loop (count + 1)
        | Error status ->
            if status.Grpc_core.Status.code = Grpc_core.Status.OK then
              printf "Stream completed after %d messages\n%!" count
            else
              printf "Stream error (%s) after %d messages\n%!" status.message count
        | exception End_of_file ->
            printf "Stream ended after %d messages\n%!" count
    in
    Fun.protect
      ~finally:(fun () -> Grpc_eio.Client.close client)
      (fun () -> loop 0);
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
