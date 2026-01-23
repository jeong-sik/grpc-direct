(** Legacy alias for protoc-gen-grpc-direct. *)

let () =
  let argv = Array.copy Sys.argv in
  argv.(0) <- "protoc-gen-grpc-direct";
  Unix.execvp "protoc-gen-grpc-direct" argv
;;
