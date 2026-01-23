open Printf

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

let encode_payload message =
  let key = (1 lsl 3) lor 2 in
  let len = String.length message in
  encode_varint key ^ encode_varint len ^ message
;;

let target = ref "http://127.0.0.1:50051"
let total_connections = ref 1000
let parallel = ref 50
let message = ref "churn"
let atomic_incr t = ignore (Atomic.fetch_and_add t 1)

let run_one ~sw ~env request successes failures =
  try
    let client = Grpc_eio.Client.connect ~sw ~env !target in
    let result =
      Grpc_eio.Client.call_unary
        ~sw
        ~env
        client
        ~service:"interop.InteropService"
        ~method_:"Unary"
        ~request
    in
    (match result with
     | Ok _ -> atomic_incr successes
     | Error _ -> atomic_incr failures);
    Grpc_eio.Client.close client
  with
  | _exn -> atomic_incr failures
;;

let () =
  let usage = "connection_churn_client [--target url] [--connections n] [--parallel n]" in
  Arg.parse
    [ "--target", Arg.Set_string target, "Target URL (default: http://127.0.0.1:50051)"
    ; "--connections", Arg.Set_int total_connections, "Total connections (default: 1000)"
    ; "--parallel", Arg.Set_int parallel, "Parallel connections per batch (default: 50)"
    ; "--message", Arg.Set_string message, "Payload message string"
    ]
    (fun _ -> ())
    usage;
  let successes = Atomic.make 0 in
  let failures = Atomic.make 0 in
  let request = encode_payload !message in
  Eio_main.run
  @@ fun env ->
  let run_batch batch =
    let remaining = ref batch in
    let done_promise, done_resolver = Eio.Promise.create () in
    let mark_done () =
      remaining := !remaining - 1;
      if !remaining = 0 then Eio.Promise.resolve done_resolver ()
    in
    try
      Eio.Switch.run
      @@ fun sw ->
      for _ = 1 to batch do
        Eio.Fiber.fork ~sw (fun () ->
          run_one ~sw ~env request successes failures;
          mark_done ())
      done;
      Eio.Promise.await done_promise;
      Eio.Switch.fail sw Exit
    with
    | Exit -> ()
  in
  let rec run_batches remaining =
    if remaining <= 0
    then ()
    else (
      let batch = min remaining !parallel in
      run_batch batch;
      run_batches (remaining - batch))
  in
  run_batches !total_connections;
  let ok = Atomic.get successes in
  let failed = Atomic.get failures in
  printf "Churn complete: ok=%d failed=%d total=%d\n%!" ok failed (ok + failed)
;;
