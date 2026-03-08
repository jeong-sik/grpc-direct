(** grpc-core: Pure OCaml gRPC core library.

    Provides the fundamental building blocks for gRPC communication:
    - {!module:Message} -- Length-prefixed message framing.
    - {!module:Codec}   -- Compression codecs (identity, gzip, zstd).
    - {!module:Status}  -- gRPC status codes.
    - {!module:Timeout} -- Timeout parsing and formatting.
    - {!module:Version} -- Library version (via dune-build-info).

    This library has no runtime dependencies (no Eio / Lwt / Async). *)

module Codec = Codec
module Status = Status
module Message = Message
module Timeout = Timeout
module Version = Version
