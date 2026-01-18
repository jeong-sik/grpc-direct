(** grpc-core: Pure OCaml gRPC core library.

    This module provides the fundamental building blocks for gRPC:
    - Message framing (length-prefixed)
    - Compression codecs (identity, gzip)
    - Status codes
    - Timeout parsing

    It has no runtime dependencies (no Eio/Lwt/Async). *)

module Codec = Codec
module Status = Status
module Message = Message
module Timeout = Timeout
