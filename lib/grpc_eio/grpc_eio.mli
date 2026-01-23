(** grpc-direct: OCaml 5 gRPC library using Eio effects.

    This module provides the high-level API for gRPC servers and clients.
    Built on top of grpc-core for protocol handling and h2-eio for HTTP/2.

    {b Features:}
    - Pure OCaml implementation with gzip compression
    - Effect-based concurrency (no Lwt/Async)
    - Interceptor chain for cross-cutting concerns (unary + stream)
    - Type-safe service definitions
    - Connection pooling with load balancing
    - Health checking and reflection services

    {b Thread Safety:}
    Most modules are single-domain safe. For multi-domain usage,
    see individual module documentation.

    {b Example server:}
    {[
      let () = Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        let server = Server.create ()
          |> Server.add_service my_service
          |> Server.with_interceptor (Interceptor.logging ())
        in
        Server.serve ~sw ~env server
    ]}

    {b Example client:}
    {[
      let () = Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        let client = Client.connect ~sw ~env "http://localhost:50051" in
        let result = Client.call_unary ~sw ~env client
          ~service:"my.Service"
          ~method_:"MyMethod"
          ~request:request_bytes
        in
        match result with
        | Ok response -> print_endline "OK"
        | Error status -> print_endline status.message
    ]} *)

(** Interceptor chain for cross-cutting concerns *)
module Interceptor = Interceptor

(** Close-aware stream wrapper used for gRPC streaming APIs *)
module Stream = Grpc_stream

(** Service definition and method registration *)
module Service = Service

(** gRPC server with HTTP/2 and TLS support *)
module Server = Server

(** High-performance gRPC server using h2_lite (87.7% of grpc-go) *)
module Server_lite = Server_lite

(** gRPC client with all RPC types *)
module Client = Client

(** Health checking service (gRPC Health v1) *)
module Health = Health

(** Retry policies and exponential backoff *)
module Retry = Retry

(** Metrics collection (counters, gauges, histograms) *)
module Metrics = Metrics

(** Server reflection service *)
module Reflection = Reflection

(** Connection pooling *)
module Pool = Pool

(** Load balancer for multiple backends *)
module Balancer = Balancer

(** TLS configuration *)
module Tls_config = Tls_config

(** Flow-based H2 handler for TLS *)
module Flow_handler = Flow_handler

(** gRPC-Web framing utilities *)
module Grpc_web = Grpc_web

(** gRPC-Web HTTP/1.1 server *)
module Grpc_web_server = Grpc_web_server

(** gRPC-Web HTTP/1.1 client *)
module Grpc_web_client = Grpc_web_client

(** gRPC-Web WebSocket gateway *)
module Grpc_web_ws_server = Grpc_web_ws_server
