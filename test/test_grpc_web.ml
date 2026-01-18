(** Tests for gRPC-Web framing and base64. *)

let test_base64_roundtrip () =
  let input = "hello grpc-web" in
  let encoded = Grpc_eio.Grpc_web.Base64.encode input in
  let decoded = Grpc_eio.Grpc_web.Base64.decode encoded in
  match decoded with
  | Ok out -> assert (out = input)
  | Error e -> failwith ("Base64 decode failed: " ^ e)

let test_base64_streaming () =
  let input = "streaming-base64-check" in
  let (part1, part2) =
    let mid = String.length input / 2 in
    (String.sub input 0 mid, String.sub input mid (String.length input - mid))
  in
  let open Grpc_eio.Grpc_web.Base64.Stream in
  let out1, st = encode_chunk enc_init part1 in
  let out2, st = encode_chunk st part2 in
  let out3 = encode_final st in
  let encoded = out1 ^ out2 ^ out3 in
  let decoded = Grpc_eio.Grpc_web.Base64.decode encoded in
  match decoded with
  | Ok out -> assert (out = input)
  | Error e -> failwith ("Streaming base64 decode failed: " ^ e)

let test_frame_roundtrip () =
  let payload = "hello" in
  let frame = match Grpc_core.Message.encode ~codec:Grpc_core.Codec.identity payload with
    | Ok f -> f
    | Error e -> failwith e
  in
  let body = Grpc_eio.Grpc_web.encode_frame (Grpc_eio.Grpc_web.Message frame) in
  match Grpc_eio.Grpc_web.decode_frames_complete body with
  | Error e -> failwith ("Frame decode failed: " ^ e)
  | Ok [Grpc_eio.Grpc_web.Message decoded_frame] ->
      (match Grpc_core.Message.decode ~codec:Grpc_core.Codec.identity decoded_frame with
       | Ok msg -> assert (msg = payload)
       | Error e -> failwith ("Message decode failed: " ^ e))
  | Ok _ -> failwith "Unexpected frame layout"

let test_trailers_frame () =
  let trailers = [("grpc-status", "0"); ("grpc-message", "OK")] in
  let body = Grpc_eio.Grpc_web.encode_frame (Grpc_eio.Grpc_web.Trailers trailers) in
  match Grpc_eio.Grpc_web.decode_frames_complete body with
  | Error e -> failwith ("Trailer decode failed: " ^ e)
  | Ok [Grpc_eio.Grpc_web.Trailers decoded] ->
      assert (List.assoc "grpc-status" decoded = "0");
      assert (List.assoc "grpc-message" decoded = "OK")
  | Ok _ -> failwith "Unexpected trailer frame layout"

let () =
  Printf.printf "\n=== grpc-web tests ===\n\n%!";
  test_base64_roundtrip ();
  test_base64_streaming ();
  test_frame_roundtrip ();
  test_trailers_frame ();
  Printf.printf "✅ grpc-web framing/base64 tests passed\n%!"
