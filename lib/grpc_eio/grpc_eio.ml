(** grpc-direct: OCaml 5 gRPC library using Eio effects.

    This module provides the high-level API for gRPC servers and clients.
    Built on top of grpc-core for protocol handling and h2-eio for HTTP/2.

    Features:
    - Pure OCaml implementation with gzip compression
    - Effect-based concurrency (no Lwt/Async)
    - Interceptor chain for cross-cutting concerns
    - Type-safe service definitions

    Example server:
    {[
      let () = Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        let server = Server.create ()
          |> Server.add_service my_service
          |> Server.with_interceptor (Interceptor.logging ())
        in
        Server.serve ~sw ~env server
    ]}

    Example client:
    {[
      let () = Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        let client = Client.connect ~sw ~env "http://localhost:50051" in
        let result = Client.call_unary client
          ~service:"my.Service"
          ~method_:"MyMethod"
          ~request:request_bytes
        in
        match result with
        | Ok response -> print_endline "OK"
        | Error status -> print_endline status.message
    ]} *)

(** Re-export submodules as a unified API.

    This facade module exists for ergonomic reasons:
    - Users can [open Grpc_eio] and access [Server.create], [Client.connect], etc.
    - Avoids exposing internal modules like [Http2_handler] or [Tls_config]
    - Matches conventions of other OCaml libraries (e.g., Eio, Cohttp) *)

module Interceptor = Interceptor
module Stream = Grpc_stream
module Service = Service
module Server = Server
module Server_lite = Server_lite
module Client = Client
module Health = Health
module Retry = Retry
module Metrics = Metrics
module Reflection = Reflection
module Pool = Pool
module Balancer = Balancer
module Tls_config = Tls_config
module Flow_handler = Flow_handler
module Grpc_web = Grpc_web
module Grpc_web_server = Grpc_web_server
module Grpc_web_client = Grpc_web_client
module Grpc_web_ws_server = Grpc_web_ws_server
module Algorithms = Algorithms
