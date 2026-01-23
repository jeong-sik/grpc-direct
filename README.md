# grpc-direct

**Experimental gRPC for OCaml 5.x** — Eio-first, effect-based, no Lwt/Async.

[![OCaml 5.x](https://img.shields.io/badge/OCaml-5.x-orange.svg)](https://ocaml.org/)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)
[![Built with LLM](https://img.shields.io/badge/Built%20with-LLM%20Assistance-blueviolet.svg)](#development)

> 🧪 **Experimental**
> This is a personal learning project, not production-ready.
> Feedback and contributions are welcome!

**Naming**: project `grpc-direct`; Eio library `grpc_eio`; core library `grpc_core`.  
**Current version**: `v0.1.0` (experimental; matches opam/dune).

This library is Eio-native and effect-based. For alternatives, see
[grpc-ocaml](https://github.com/blandinw/grpc-ocaml) and
[ocaml-grpc](https://github.com/dialohq/ocaml-grpc) (refer to their docs for current details).

## Installation

Requires OCaml 5.1+.

If/when published on opam:
```bash
opam install grpc-direct
```

From source:
```bash
git clone https://github.com/jeong-sik/grpc-direct
cd grpc-direct
opam pin add grpc-direct .
```

Or add to your dune-project:
```lisp
(depends
  (grpc-direct (>= 0.1.0)))
```

## Quick Start

```ocaml
(* Minimal server - sensible defaults out of the box *)
let () = Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let service = Grpc_eio.Service.create "helloworld.Greeter"
    |> Grpc_eio.Service.add_unary "SayHello" (fun req -> "Hello, " ^ req ^ "!")
  in
  Grpc_eio.Server.create ()
  |> Grpc_eio.Server.add_service service
  |> Grpc_eio.Server.serve ~sw ~env
```

**Convention over configuration** - sensible defaults:
- Port: `50051` (gRPC standard)
- Host: `127.0.0.1`
- Max message: `4MB`
- Timeout: `30s`
- Compression: `identity` (gzip opt-in)

## Features

### Core
- ✅ gzip + identity compression
- ✅ Unary, Client/Server/Bidi streaming RPCs
- ✅ Interceptor chain (middleware pattern)
- ✅ **Native TLS** (ALPN h2, tls-eio)
- ✅ **gRPC-Web** (HTTP/1.1 binary/text; WebSocket gateway for streaming/bidi)
- ✅ OCaml 5.x effects (no Lwt/Async)

### Feature Set (v0.1.0, experimental)
- ✅ **Health Check** - `grpc.health.v1.Health` service
- ✅ **Retry Policy** - Exponential backoff with jitter
- ✅ **Metrics** - Prometheus-compatible metrics
- ✅ **Server Reflection** - `grpcurl` service discovery
- ✅ **Connection Pool** - Reusable connections
- ✅ **Load Balancer** - Round Robin, Weighted, Random

## Status Snapshot (2026-01-23)

- Scope: HTTP/2 + gRPC + gRPC-Web implementation in this repo
- Interop: Go/Rust suites + official grpc-go scripts included (results not published)
- Compliance: h2spec runner included (results not published; see `docs/COMPLIANCE.md`)
- Resilience: slow reader/churn/cancel scripts (see `docs/RESILIENCE.md`)
- Ops: Prometheus metrics + alert templates (see `ops/prometheus/`)
- Performance: not published yet (public benchmarks TBD)
- Soak: TBD (not published)
- Known skips (by design): auth/creds/ORCA + custom metadata interop cases (see `docs/INTEROP-SUITE.md`)
- Pending: broader examples, codegen ergonomics

## Self-assessment

**Strengths**
- Protocol-aligned wire behavior for core paths in a pure OCaml stack
- Eio-first structured concurrency (clear lifetimes, no callback sprawl)
- h2_lite path for throughput-sensitive services

**Gaps**
- Official interop cases requiring auth/creds/ORCA/custom metadata are not supported
- Browser gRPC-Web client streaming/bidi requires the WebSocket gateway
- Codegen and ecosystem polish still catching up

## API Reference

### Server

```ocaml
(* Create server with all features *)
let server =
  Grpc_eio.Reflection.create_server_with_reflection ()  (* Reflection enabled *)
  |> Grpc_eio.Server.add_service my_service
  |> Grpc_eio.Server.add_service (Grpc_eio.Health.to_service health)
  |> Grpc_eio.Server.with_interceptor (Grpc_eio.Metrics.server_interceptor metrics)
in
Grpc_eio.Server.serve ~sw ~env server
```

### Client with Retry

```ocaml
let policy = Grpc_eio.Retry.{
  max_attempts = 3;
  initial_backoff = 0.1;
  max_backoff = 1.0;
  backoff_multiplier = 2.0;
  retryable_codes = [Unavailable; Resource_exhausted];
  jitter = 0.2;
} in

let client = Grpc_eio.Client.connect ~sw ~env target
  |> Grpc_eio.Client.with_interceptor (Grpc_eio.Retry.interceptor ~policy ())
  |> Grpc_eio.Client.with_interceptor (Grpc_eio.Metrics.client_interceptor metrics)
```

### Connection Pool

```ocaml
let pool = Grpc_eio.Pool.create
  ~min_connections:2
  ~max_connections:20
  ~target:"http://localhost:50051"
  () in

Grpc_eio.Pool.warm_up ~sw ~env pool;

Grpc_eio.Pool.with_connection ~sw ~env pool (fun client ->
  Grpc_eio.Client.call_unary client ~service:"..." ~method_:"..." ~request
)
```

### Load Balancer

```ocaml
(* Round Robin across 3 backends *)
let lb = Grpc_eio.Balancer.create
  ~strategy:RoundRobin
  ~targets:["http://s1:50051"; "http://s2:50051"; "http://s3:50051"]
  ()

(* Weighted Round Robin (3:1 ratio) *)
let lb = Grpc_eio.Balancer.create
  ~strategy:(WeightedRoundRobin [3; 1])
  ~targets:["http://fast:50051"; "http://slow:50051"]
  ()

(* Enable per-backend connection pooling *)
let lb = Grpc_eio.Balancer.create
  ~pool_options:Grpc_eio.Balancer.default_pool_options
  ~targets:["http://s1:50051"; "http://s2:50051"]
  ()

(* Call with automatic failover *)
Grpc_eio.Balancer.call_with_retry ~sw ~env ~max_retries:3 lb (fun client ->
  Grpc_eio.Client.call_unary client ~service ~method_ ~request
)
```

### Health Check

```ocaml
let health = Grpc_eio.Health.create () in
Grpc_eio.Health.set_status health ~service:"myapp.Greeter" Serving;

(* Add to server *)
Grpc_eio.Server.add_service (Grpc_eio.Health.to_service health) server

(* Query with grpcurl *)
(* grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check *)
```

### Metrics (Prometheus)

```ocaml
let metrics = Grpc_eio.Metrics.create () in

(* Attach metrics registry (covers streaming sizes too) *)
Grpc_eio.Server.with_metrics metrics server

(* Expose metrics endpoint *)
Grpc_eio.Metrics.serve_prometheus ~sw ~env metrics
```

### TLS

```ocaml
let tls = Grpc_eio.Tls_config.{
  cert_file = "server.pem";
  key_file = "server.key"
} in
Grpc_eio.Server.create ~tls ()
|> Grpc_eio.Server.serve ~sw ~env
```

### HTTP/2 Advanced (H2_lite)

```ocaml
let on_push (push : H2_lite.push_response) =
  Eio.traceln "PUSH %ld" push.promised_stream_id

let _client =
  H2_lite.Client.connect ~sw ~env ~host:"127.0.0.1" ~port:8080 ()
    ~enable_push:true ~on_push

let handler stream request =
  let prio : H2_lite.Frame.priority_info = {
    exclusive = false; dependency = 0l; weight = 200
  } in
  H2_lite.send_priority stream prio;
  let pushed = H2_lite.send_push_promise stream ~headers:[
    (":method", "GET"); (":path", "/asset.css");
    (":scheme", "http"); (":authority", "localhost");
  ] in
  H2_lite.send_headers pushed ~end_stream:true [
    (":status", "200"); ("content-type", "text/css")
  ];
  request
```

## Modules

| Module | Description |
|--------|-------------|
| `Server` | HTTP/2 server with service routing |
| `Client` | HTTP/2 client with interceptors |
| `Service` | Service/method definitions |
| `Interceptor` | Middleware chain |
| `Health` | gRPC Health Check v1 |
| `Retry` | Retry policy with backoff |
| `Metrics` | Prometheus metrics |
| `Reflection` | Server reflection for grpcurl |
| `Pool` | Connection pooling |
| `Balancer` | Client-side load balancing |

## Packages (opam)

| Package | Provides |
|---------|----------|
| `grpc-direct-core` | Library `grpc_core` (framing, compression, status codes) |
| `grpc-direct` | Library `grpc_eio` (server/client + Eio features) |
| `grpc-direct-protoc` | `protoc-gen-grpc-direct` plugin + `grpc_protoc` library |

## Naming

- Repo/opam: `grpc-direct`
- Core lib: `grpc_core` (`grpc-direct-core`)
- Eio lib: `grpc_eio` (`grpc-direct`)
- Protoc plugin: `protoc-gen-grpc-direct` (legacy alias: `protoc-gen-grpc-eio`)

## Code Generation (protoc)

Generate protobuf message types with `ocaml-protoc-plugin`, then generate gRPC
stubs with `protoc-gen-grpc-direct`:

```bash
protoc \
  --ocaml_out=. \
  --grpc-direct_out=. \
  --plugin=protoc-gen-grpc-direct=$(which protoc-gen-grpc-direct) \
  your/service.proto
```

## Benchmarks

```bash
# Codec benchmark
dune exec bench/bench_codec.exe

# gRPC echo server (h2_lite backend)
dune exec lib/grpc_eio/h2_lite/echo_server.exe

# Benchmark with ghz
ghz --insecure --proto bench/go-comparison/echo.proto \
    --call echo.EchoService/Echo -d '{"message":"hello"}' \
    -c 50 -n 100000 localhost:50051
```

Benchmarks are **not published yet** (by design). The commands above are for local
experiments only; please treat any results as preliminary and non-authoritative.

## Alternatives

- [grpc-ocaml](https://github.com/blandinw/grpc-ocaml)
- [ocaml-grpc](https://github.com/dialohq/ocaml-grpc)

Each project targets different runtime ecosystems and feature scopes; refer to
their READMEs for current details.

## Documentation

- [examples/](examples/) - Usage examples
- [examples/production/](examples/production/) - Production-style server/client example
- [examples/h2-lite-advanced/](examples/h2-lite-advanced/) - H2_lite priority + push
- [examples/grpc-web/](examples/grpc-web/) - gRPC-Web server/client (HTTP/1.1)
- [test/](test/) - Test cases as documentation
- [docs/GRPC-WEB.md](docs/GRPC-WEB.md) - gRPC-Web usage guide
- [docs/INTEROP-SUITE.md](docs/INTEROP-SUITE.md) - Interop suites + official interop
- [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md) - Prometheus metrics + alerts
- [docs/COMPARISON.md](docs/COMPARISON.md) - Cross-language comparison (qualitative, draft)
- [docs/PERF-BASELINE.md](docs/PERF-BASELINE.md) - Baseline procedure (numbers not published)
- [docs/PROD-READINESS.md](docs/PROD-READINESS.md) - Readiness checklist (draft)
- [docs/PERFORMANCE-RESEARCH.md](docs/PERFORMANCE-RESEARCH.md) - Performance notes (draft)
- [ops/prometheus/](ops/prometheus/) - Prometheus deployment templates
- [ops/soak/](ops/soak/) - Soak test runner
- [CHANGELOG.md](CHANGELOG.md) - Version history
- [ROADMAP.md](ROADMAP.md) - Future plans

## Development

> **🤖 LLM-First Development**
> This project was **fully developed with LLM assistance** (Claude, Gemini, Codex, etc.).
> All code, documentation, and tests were generated through human-AI collaboration.
> The maintainer reviewed, tested, and validated all outputs.

## License

Apache-2.0
