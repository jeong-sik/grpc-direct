# Changelog

All notable changes to grpc-eio-next.

> Note: This project is experimental.  
> Changelog entries are draft notes and not a public release record.

## [Unreleased] - Draft

### Added
- **Production Readiness (draft)** - Complete feature set for future production deployments
- Comprehensive README with API documentation
- Module comparison table vs ocaml-grpc and grpc-ocaml
- Benchmark plan (no published results)

### Changed
- Updated package descriptions to reflect experimental status
- Versioning TBD

## [0.4.0] - 2025-01-11

### Added
- **Connection Pool** (`Pool` module)
  - Configurable min/max connections
  - Idle timeout with automatic eviction
  - Health checking
  - `with_connection` for automatic release
  - `warm_up` for pre-warming connections
  - Thread-safe with `Eio.Mutex`

- **Load Balancer** (`Balancer` module)
  - PickFirst, RoundRobin, WeightedRoundRobin, Random strategies
  - Automatic health tracking with failure thresholds
  - `call_with_retry` for failover support
  - Backend statistics

## [0.3.0] - 2025-01-11

### Added
- **Server Reflection** (`Reflection` module)
  - `grpc.reflection.v1.ServerReflection` service
  - `grpcurl` service discovery support
  - `list_services` and `file_containing_symbol` methods
  - `create_server_with_reflection` helper

## [0.3.0-beta] - 2025-01-11

### Added
- **Retry Policy** (`Retry` module)
  - Exponential backoff with configurable jitter
  - Retryable status codes (Unavailable, ResourceExhausted, etc.)
  - Budget tracker to prevent retry storms
  - Client interceptor for transparent retries

- **Prometheus Metrics** (`Metrics` module)
  - Counter, Gauge, Histogram primitives
  - `grpc_calls_total`, `grpc_call_duration_seconds` metrics
  - Server and client interceptors
  - `to_prometheus` text format export

## [0.3.0-alpha] - 2025-01-11

### Added
- **Health Check** (`Health` module)
  - `grpc.health.v1.Health` service implementation
  - Per-service status tracking (Unknown, Serving, NotServing)
  - `to_service` for server integration

### Changed
- **BREAKING**: Client busy-wait replaced with `Eio.Promise`
  - Fixes blocking issue in concurrent calls
- **Deadline Propagation** - `grpc-timeout` header parsing in server

## [0.2.0] - 2025-01-11

### Added
- **Native TLS support** via tls-eio with ALPN "h2" negotiation
- Benchmark suite (`bench/bench_codec.ml`)
- `Tls_config` module for TLS configuration

### Changed
- **BREAKING**: `Timeout.t` changed from record to `int64` (nanoseconds)
  ```ocaml
  (* Before *)
  type t = { value: int; unit: unit_type }
  let timeout = { value = 30; unit = Seconds }

  (* After *)
  type t = int64  (* nanoseconds *)
  let timeout = Timeout.of_seconds 30
  ```
- **BREAKING**: `Timeout.parse` returns `int64` instead of record
- Server module refactored: extracted `Http2_handler` and `Tls_config`

### Migration Guide

#### Timeout API
```ocaml
(* Old *)
let t = { Timeout.value = 30; unit = Timeout.Seconds } in
let secs = float_of_int t.value in ...

(* New *)
let t = Timeout.of_seconds 30 in
let secs = Timeout.to_seconds t in ...
```

#### TLS Configuration
```ocaml
(* New - optional TLS *)
let tls = Tls_config.{ cert_file = "cert.pem"; key_file = "key.pem" } in
Server.create ~tls () |> Server.serve ~sw ~env
```

## [0.1.0] - 2025-01-01

### Added
- Initial release
- Unary and streaming RPCs
- gzip + identity compression
- Interceptor chain
- OCaml 5.x effects-based I/O
