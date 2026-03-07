(** Embedding Client - Batch embedding with Connection Pool

    Run with: dune exec examples/embedding-service/embedding_client.exe

    This demonstrates:
    - Connection pooling for performance
    - Batch processing multiple texts
    - Response parsing
    - Real-world ML client pattern
*)

(** Request builder *)
module EmbedRequest = struct
  type t =
    { model : string
    ; texts : string list
    }

  let create ?(model = "bge-m3") texts = { model; texts }
  let to_bytes t = Printf.sprintf "%s|%s" t.model (String.concat "|" t.texts)
end

(** Response parser *)
module EmbedResponse = struct
  type t =
    { model : string
    ; dimension : int
    ; usage : int
    ; embeddings : float array list
    }

  let of_bytes bytes =
    let parts = String.split_on_char '|' bytes in
    match parts with
    | model :: dim_str :: usage_str :: emb_strs ->
      let dimension = int_of_string dim_str in
      let usage = int_of_string usage_str in
      let embeddings =
        List.filter_map
          (fun s ->
             if String.length s > 0
             then
               Some
                 (String.split_on_char ',' s |> List.map float_of_string |> Array.of_list)
             else None)
          emb_strs
      in
      { model; dimension; usage; embeddings }
    | _ -> { model = "unknown"; dimension = 0; usage = 0; embeddings = [] }
  ;;
end

(** Cosine similarity for testing *)
let cosine_similarity a b =
  let dot = ref 0.0 in
  for i = 0 to Array.length a - 1 do
    dot := !dot +. (a.(i) *. b.(i))
  done;
  let norm_a = sqrt (Array.fold_left (fun acc x -> acc +. (x *. x)) 0.0 a) in
  let norm_b = sqrt (Array.fold_left (fun acc x -> acc +. (x *. x)) 0.0 b) in
  !dot /. (norm_a *. norm_b)
;;

(** Pretty print embedding info *)
let print_embedding_info idx emb =
  let dim = Array.length emb in
  let preview = Array.sub emb 0 (min 5 dim) in
  let preview_str =
    Array.to_list preview |> List.map (Printf.sprintf "%.4f") |> String.concat ", "
  in
  Printf.printf "  [%d] dim=%d, preview=[%s, ...]\n" idx dim preview_str
;;

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Printf.printf "🧮 Embedding Client (with Connection Pool)\n%!";
  Printf.printf "─────────────────────────────────────────\n%!";
  (* Create connection pool (reuses connections across requests) *)
  let pool =
    Grpc_eio.Pool.create
      ~target:"http://127.0.0.1:50051"
      ~min_connections:1
      ~max_connections:4
      ()
  in
  Printf.printf "📡 Created connection pool (max: 4 connections)\n%!";
  (* Sample texts to embed *)
  let texts =
    [ "OCaml is a functional programming language"
    ; "gRPC enables efficient microservice communication"
    ; "Machine learning models generate embeddings"
    ; "Functional programming emphasizes immutability"
    ]
  in
  Printf.printf "📤 Embedding %d texts...\n%!" (List.length texts);
  (* Build and send request using pooled connection *)
  let request = EmbedRequest.create ~model:"bge-m3" texts in
  let result =
    Grpc_eio.Pool.with_connection ~sw ~env pool (fun client ->
      Grpc_eio.Client.call_unary
        ~sw
        ~env
        client
        ~service:"ai.EmbeddingService"
        ~method_:"Embed"
        ~request:(EmbedRequest.to_bytes request))
  in
  (match result with
   | Error pool_err -> Printf.printf "❌ Pool error: %s\n%!" pool_err
   | Ok (Ok response_bytes) ->
     let response = EmbedResponse.of_bytes response_bytes in
     Printf.printf "\n✅ Received %d embeddings\n" (List.length response.embeddings);
     Printf.printf "   Model: %s\n" response.model;
     Printf.printf "   Dimension: %d\n" response.dimension;
     Printf.printf "   Token usage: %d\n" response.usage;
     Printf.printf "\n📊 Embeddings:\n";
     List.iteri print_embedding_info response.embeddings;
     (* Show similarity between related texts *)
     if List.length response.embeddings >= 4
     then (
       let emb1 = List.nth response.embeddings 0 in
       (* OCaml functional *)
       let emb4 = List.nth response.embeddings 3 in
       (* Functional programming *)
       let emb2 = List.nth response.embeddings 1 in
       (* gRPC *)
       Printf.printf "\n🔍 Similarity analysis:\n";
       Printf.printf
         "   'OCaml functional' vs 'Functional programming': %.4f\n"
         (cosine_similarity emb1 emb4);
       Printf.printf
         "   'OCaml functional' vs 'gRPC microservices': %.4f\n"
         (cosine_similarity emb1 emb2))
   | Ok (Error status) -> Printf.printf "❌ Error: %s\n%!" status.Grpc_core.Status.message);
  (* Show pool statistics *)
  let stats = Grpc_eio.Pool.stats pool in
  Printf.printf
    "\n📊 Pool stats: acquired=%d, released=%d, created=%d\n"
    stats.acquired_count
    stats.released_count
    stats.created_count;
  Grpc_eio.Pool.close pool;
  Printf.printf "\n✅ Done\n%!"
;;
