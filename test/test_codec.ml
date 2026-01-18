(** Tests for grpc-core codec *)

let test_identity () =
  let codec = Grpc_core.Codec.identity in
  let data = "Hello, gRPC!" in
  match codec.encoder data with
  | Ok encoded ->
      assert (encoded = data);
      (match codec.decoder encoded with
       | Ok decoded ->
           assert (decoded = data);
           Printf.printf "✅ Identity codec: OK\n%!"
       | Error e -> failwith e)
  | Error e -> failwith e

let test_gzip () =
  let codec = Grpc_core.Codec.gzip () in
  let data = "Hello, gRPC! This is a test message for compression." in
  Printf.printf "📦 Original size: %d bytes\n%!" (String.length data);
  match codec.encoder data with
  | Ok encoded ->
      Printf.printf "📦 Compressed size: %d bytes\n%!" (String.length encoded);
      (match codec.decoder encoded with
       | Ok decoded ->
           assert (decoded = data);
           Printf.printf "✅ Gzip codec: OK (roundtrip successful)\n%!"
       | Error e -> failwith ("Decode failed: " ^ e))
  | Error e -> failwith ("Encode failed: " ^ e)

let test_zstd () =
  let codec = Grpc_core.Codec.zstd () in
  let data = "Hello, gRPC! This is a test message for zstd compression. Compact Protocol v4!" in
  Printf.printf "📦 Original size: %d bytes\n%!" (String.length data);
  match codec.encoder data with
  | Ok encoded ->
      Printf.printf "📦 Zstd compressed size: %d bytes\n%!" (String.length encoded);
      (match codec.decoder encoded with
       | Ok decoded ->
           assert (decoded = data);
           Printf.printf "✅ Zstd codec: OK (roundtrip successful)\n%!"
       | Error e -> failwith ("Decode failed: " ^ e))
  | Error e -> failwith ("Encode failed: " ^ e)

let test_zstd_large () =
  let codec = Grpc_core.Codec.zstd () in
  (* Create a large repetitive message - typical LLM response pattern *)
  let data = String.concat "" (List.init 100 (fun i ->
    Printf.sprintf "{\"id\":%d,\"type\":\"response\",\"status\":\"ok\"}" i
  )) in
  Printf.printf "📦 Large JSON size: %d bytes\n%!" (String.length data);
  match codec.encoder data with
  | Ok encoded ->
      let ratio = float_of_int (String.length encoded) /. float_of_int (String.length data) in
      Printf.printf "📦 Zstd compressed: %d bytes (%.1f%%)\n%!" (String.length encoded) (ratio *. 100.);
      (match codec.decoder encoded with
       | Ok decoded ->
           assert (decoded = data);
           Printf.printf "✅ Zstd large message: OK\n%!"
       | Error e -> failwith ("Decode failed: " ^ e))
  | Error e -> failwith ("Encode failed: " ^ e)

let test_message_framing_zstd () =
  let codec = Grpc_core.Codec.zstd () in
  let data = "Test message with zstd compression for gRPC framing - Compact Protocol v4" in
  match Grpc_core.Message.encode ~codec data with
  | Error e -> failwith ("Encode failed: " ^ e)
  | Ok frame ->
  Printf.printf "📦 Zstd frame size: %d bytes\n%!" (String.length frame);
  match Grpc_core.Message.decode ~codec frame with
  | Ok decoded ->
      assert (decoded = data);
      Printf.printf "✅ Message framing (zstd): OK\n%!"
  | Error e -> failwith e

let test_message_framing () =
  let codec = Grpc_core.Codec.identity in
  let data = "Test message" in
  match Grpc_core.Message.encode ~codec data with
  | Error e -> failwith ("Encode failed: " ^ e)
  | Ok frame ->
  Printf.printf "📦 Frame size: %d bytes (data: %d + header: 5)\n%!"
    (String.length frame) (String.length data);
  match Grpc_core.Message.decode ~codec frame with
  | Ok decoded ->
      assert (decoded = data);
      Printf.printf "✅ Message framing: OK\n%!"
  | Error e -> failwith e

let test_message_framing_gzip () =
  let codec = Grpc_core.Codec.gzip () in
  let data = "Test message with gzip compression for framing" in
  match Grpc_core.Message.encode ~codec data with
  | Error e -> failwith ("Encode failed: " ^ e)
  | Ok frame ->
  Printf.printf "📦 Gzip frame size: %d bytes\n%!" (String.length frame);
  match Grpc_core.Message.decode ~codec frame with
  | Ok decoded ->
      assert (decoded = data);
      Printf.printf "✅ Message framing (gzip): OK\n%!"
  | Error e -> failwith e

let test_negotiate () =
  let supported = [Grpc_core.Codec.gzip (); Grpc_core.Codec.identity] in
  let codec = Grpc_core.Codec.negotiate ~supported ~accepted:"gzip, identity" in
  assert (codec.name = "gzip");
  let codec2 = Grpc_core.Codec.negotiate ~supported ~accepted:"identity" in
  assert (codec2.name = "identity");
  let codec3 = Grpc_core.Codec.negotiate ~supported ~accepted:"deflate" in
  assert (codec3.name = "identity");  (* fallback to identity *)
  Printf.printf "✅ Codec negotiation: OK\n%!"

let test_negotiate_zstd () =
  let supported = [Grpc_core.Codec.zstd (); Grpc_core.Codec.gzip (); Grpc_core.Codec.identity] in
  let codec = Grpc_core.Codec.negotiate ~supported ~accepted:"zstd, gzip, identity" in
  assert (codec.name = "zstd");
  let codec2 = Grpc_core.Codec.negotiate ~supported ~accepted:"gzip" in
  assert (codec2.name = "gzip");
  Printf.printf "✅ Zstd negotiation: OK\n%!"

let () =
  Printf.printf "\n=== grpc-core tests ===\n\n%!";
  test_identity ();
  test_gzip ();
  test_zstd ();
  test_zstd_large ();
  test_message_framing ();
  test_message_framing_gzip ();
  test_message_framing_zstd ();
  test_negotiate ();
  test_negotiate_zstd ();
  Printf.printf "\n=== All tests passed! ===\n%!"
