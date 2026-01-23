(** Embedding Service - Batch text embedding like OpenAI/Cohere

    Run with: dune exec examples/embedding-service/embedding_server.exe

    This demonstrates:
    - Unary RPC with batch processing
    - Health check integration
    - Metrics collection
    - Real-world ML inference pattern
*)

(** Embedding request/response types *)
module EmbedRequest = struct
  type t =
    { model : string
    ; texts : string list
    }

  let of_bytes bytes =
    (* Format: model|text1|text2|... *)
    match String.split_on_char '|' bytes with
    | model :: texts -> { model; texts }
    | _ -> { model = "bge-m3"; texts = [ bytes ] }
  ;;
end

module EmbedResponse = struct
  type embedding = float array

  type t =
    { embeddings : embedding list
    ; model : string
    ; usage : int (* token count *)
    }

  let to_bytes t =
    (* Format: model|dim|emb1,emb2,...|emb1,emb2,... *)
    let dim =
      match t.embeddings with
      | [] -> 0
      | e :: _ -> Array.length e
    in
    let emb_strs =
      List.map
        (fun e -> Array.to_list e |> List.map string_of_float |> String.concat ",")
        t.embeddings
    in
    Printf.sprintf "%s|%d|%d|%s" t.model dim t.usage (String.concat "|" emb_strs)
  ;;
end

(** Simulated embedding model *)
module EmbeddingModel = struct
  let dimension = 1024 (* BGE-M3 style *)

  let embed_text text =
    (* Simulate embedding generation *)
    (* In production: call actual model via ONNX/TensorRT *)
    let hash = Hashtbl.hash text in
    Random.init hash;
    Array.init dimension (fun _ -> Random.float 2.0 -. 1.0)
  ;;

  let embed_batch texts = List.map embed_text texts

  let count_tokens text =
    (* Simple token estimation *)
    (String.length text / 4) + 1
  ;;
end

(** Embedding handler *)
let embed (request_bytes : string) : string =
  let request = EmbedRequest.of_bytes request_bytes in
  Printf.printf
    "📊 [Embed] Processing %d texts with model %s"
    (List.length request.texts)
    request.model;
  (* Simulate model inference time *)
  let start = Unix.gettimeofday () in
  let embeddings = EmbeddingModel.embed_batch request.texts in
  let elapsed = Unix.gettimeofday () -. start in
  let usage =
    List.fold_left (fun acc t -> acc + EmbeddingModel.count_tokens t) 0 request.texts
  in
  Printf.printf
    "📊 [Embed] Generated %d embeddings in %.3fs (%d tokens)"
    (List.length embeddings)
    elapsed
    usage;
  let response = EmbedResponse.{ embeddings; model = request.model; usage } in
  EmbedResponse.to_bytes response
;;

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  (* Create health service using the library's Health module *)
  let health = Grpc_eio.Health.create () in
  Grpc_eio.Health.set_status health ~service:"" Grpc_eio.Health.Serving;
  (* overall *)
  Grpc_eio.Health.set_status health ~service:"ai.EmbeddingService" Grpc_eio.Health.Serving;
  (* Create embedding service *)
  let embed_service =
    Grpc_eio.Service.create "ai.EmbeddingService"
    |> Grpc_eio.Service.add_unary "Embed" embed
  in
  (* Create server with health service from library *)
  let server =
    Grpc_eio.Server.create ()
    |> Grpc_eio.Server.add_service embed_service
    |> Grpc_eio.Server.add_service (Grpc_eio.Health.to_service health)
    |> Grpc_eio.Server.with_interceptor (Grpc_eio.Interceptor.logging ())
  in
  Printf.printf "🧮 Embedding Server starting on port 50051...\n%!";
  Printf.printf "   Model: bge-m3 (simulated)\n%!";
  Printf.printf "   Dimension: %d\n%!" EmbeddingModel.dimension;
  Printf.printf "   Health: /grpc.health.v1.Health/Check\n%!";
  Printf.printf "\n";
  Printf.printf "Test with:\n";
  Printf.printf "  dune exec examples/embedding-service/embedding_client.exe\n%!";
  Printf.printf "  grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check\n%!";
  Grpc_eio.Server.serve ~sw ~env server
;;
