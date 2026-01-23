# gRPC Implementation Comparison

Comprehensive comparison of grpc-eio with other language implementations.

> Note: Public performance benchmarks are not published yet.  
> This document focuses on qualitative comparisons for now.

## Summary Table (8 implementations)

### Qualitative Summary

| Implementation | Core spec | Web | Stability & Ops | UX | Examples |
|---------------|-----------|-----|-----------------|----|----------|
| **grpc-eio (OCaml)** | **Full (interop pass)** | bridge+ws | High | Mid-High | Mid-High |
| grpc/grpc (C++) | Full | proxy | Top | Low | Rich |
| grpc-go | Full | proxy | Top | High | Rich |
| tonic (Rust) | Full | proxy | High | Mid | Rich |
| grpc-java | Full | proxy | Top | High | Rich |
| grpc-dotnet | Full | proxy | Top | High | Rich |
| grpcio (Python) | Full | proxy | High | High | Rich |
| grpc-js (Node) | Full | proxy | Mid-High | High | Rich |

## Feature Matrix

| Feature | grpc-eio (OCaml) | grpc-go | tonic (Rust) | grpcio (Python) | grpc-java |
|---------|------------------|---------|--------------|-----------------|-----------|
| **Protocol** |
| HTTP/2 | ✅ h2 library | ✅ Native | ✅ hyper | ✅ Core | ✅ Netty |
| TLS | ✅ ocaml-tls | ✅ Native | ✅ rustls/native | ✅ OpenSSL | ✅ Netty SSL |
| mTLS | ✅ | ✅ | ✅ | ✅ | ✅ |
| gRPC-Web (browser) | ✅ HTTP/1.1 bridge + WS | ✅ proxy | ✅ proxy | ✅ proxy | ✅ proxy |
| **RPC Types** |
| Unary | ✅ | ✅ | ✅ | ✅ | ✅ |
| Server streaming | ✅ | ✅ | ✅ | ✅ | ✅ |
| Client streaming | ✅ | ✅ | ✅ | ✅ | ✅ |
| Bidirectional | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Features** |
| Interceptors | ✅ | ✅ | ✅ Tower | ✅ | ✅ |
| Deadline propagation | ✅ | ✅ | ✅ | ✅ | ✅ |
| Keep-alive/Ping | ✅ | ✅ | ✅ | ✅ | ✅ |
| Retry policy | ✅ | ✅ | ⚠️ Manual | ⚠️ Manual | ✅ |
| Load balancing | ✅ | ✅ | ⚠️ Tower | ❌ | ✅ |
| Health checking | ✅ ping() | ✅ | ✅ | ✅ | ✅ |
| **Compression** |
| Identity | ✅ | ✅ | ✅ | ✅ | ✅ |
| Gzip | ✅ | ✅ | ✅ | ✅ | ✅ |
| Deflate | ❌ | ✅ | ❌ | ✅ | ✅ |
| Snappy | ❌ | ✅ | ❌ | ❌ | ❌ |
| Zstd | ❌ | ✅ | ⚠️ | ❌ | ❌ |
| **Auth** |
| Insecure | ✅ | ✅ | ✅ | ✅ | ✅ |
| TLS | ✅ | ✅ | ✅ | ✅ | ✅ |
| Token auth | ✅ Credentials | ✅ | ✅ | ✅ | ✅ |
| OAuth2 | ⚠️ Manual | ✅ | ⚠️ | ✅ | ✅ |
| Google ADC | ❌ | ✅ | ❌ | ✅ | ✅ |
| **Code Gen** |
| protoc plugin | ✅ protoc-gen-grpc-eio | ✅ | ✅ prost | ✅ | ✅ |
| Reflection | ✅ | ✅ | ✅ | ✅ | ✅ |

## Architecture Comparison

### Concurrency Model

| Implementation | Model | Strengths |
|----------------|-------|-----------|
| **grpc-eio** | Eio effects (structured concurrency) | Simple, composable, no callbacks |
| grpc-go | Goroutines + channels | Lightweight, familiar Go patterns |
| tonic | Tokio async/await | Zero-cost abstractions, excellent perf |
| grpcio | Threads + asyncio | Flexible, Python ecosystem |
| grpc-java | Netty event loop | Mature, battle-tested |

### Type Safety

| Implementation | Type System | Benefits |
|----------------|-------------|----------|
| **grpc-eio** | OCaml (strong, inferred) | No runtime type errors, compile-time guarantees |
| grpc-go | Go (structural) | Simple, fast compile |
| tonic | Rust (ownership + lifetimes) | Memory safety, zero-cost abstractions |
| grpcio | Python (dynamic) | Flexibility, rapid prototyping |
| grpc-java | Java (nominal) | IDE support, enterprise tooling |

### Error Handling

| Implementation | Style | Example |
|----------------|-------|---------|
| **grpc-eio** | Result type | `(string, Status.t) result` |
| grpc-go | Error return | `resp, err := client.Call()` |
| tonic | Result type | `Result<Response, Status>` |
| grpcio | Exceptions | `try: ... except grpc.RpcError` |
| grpc-java | Exceptions | `try { } catch (StatusRuntimeException e)` |

## Unique grpc-eio Features

### 1. Structured Concurrency with Eio

```ocaml
(* All resources automatically cleaned up when switch exits *)
Eio.Switch.run @@ fun sw ->
let client = Client.connect ~sw ~env target in
let responses = Client.call_bidi ~sw ~env client ~service ~method_ ~requests in
(* Streaming handled automatically *)
```

### 2. Type-Safe Credentials Abstraction

```ocaml
(* Compile-time guarantee of correct credential usage *)
let creds = Credentials.mtls ~ca_file ~cert_file ~key_file () in
let config = config_with_credentials ~target ~credentials:creds in
(* Cannot accidentally mix insecure with TLS endpoints *)
```

### 3. Composable Interceptors

```ocaml
let client = Client.connect ~sw ~env target
  |> Client.with_interceptor logging_interceptor
  |> Client.with_interceptor retry_interceptor
  |> Client.with_interceptor metrics_interceptor
```

### 4. Native TLS with ocaml-tls

- Pure OCaml implementation (no C bindings)
- Memory-safe by construction
- Easy to audit and verify

### 5. Per-Call Deadline Override

```ocaml
(* Quick call with tight deadline *)
Client.call_unary ~sw ~env ~deadline:0.5 client ~service ~method_ ~request

(* Long-running call with extended deadline *)
Client.call_unary ~sw ~env ~deadline:300.0 client ~service ~method_ ~request
```

## When to Choose grpc-eio

### Good Fit ✅

- **OCaml/ML ecosystem**: Native integration, no FFI overhead
- **Type safety critical**: Financial, medical, security applications
- **Structured concurrency**: Clean resource management needed
- **Memory efficiency**: Low footprint requirements
- **Auditability**: Pure OCaml TLS implementation
- **gRPC-Web**: HTTP/1.1 bridge with CORS (binary + text)

### Consider Alternatives ⚠️

- **Maximum throughput**: Rust tonic is faster
- **Enterprise ecosystem**: Java/Go have more tooling
- **Protobuf codegen**: grpc-eio requires manual message handling

## New in v0.4.0: State-of-the-Art Algorithms

grpc-eio now includes cutting-edge algorithms from systems research:

### Power of Two Choices (P2C) Load Balancer
Based on Google Maglev. O(log log n) max load vs O(log n) for random.
```ocaml
let lb = Algorithms.P2C.create [("server1", 1.0); ("server2", 1.0)] in
match Algorithms.P2C.acquire lb with
| Some server -> (* use server *)
| None -> (* all servers down *)
```

### Lock-free Ring Buffer
LMAX Disruptor pattern for high-throughput message queuing.
```ocaml
let buf = Algorithms.RingBuffer.create 1024 in
ignore (Algorithms.RingBuffer.try_push buf msg);
match Algorithms.RingBuffer.try_pop buf with
| Some msg -> (* process *)
| None -> (* empty *)
```

### Adaptive Batching
Netflix Zuul-inspired request coalescing.
```ocaml
let batcher = Algorithms.AdaptiveBatching.create () in
match Algorithms.AdaptiveBatching.add batcher request with
| Some batch -> (* process batch *)
| None -> (* still accumulating *)
```

### HDR Histogram
Accurate percentile tracking with bounded memory.
```ocaml
let hist = Algorithms.ExpHistogram.create ~min_value:0.001 ~max_value:10.0 in
Algorithms.ExpHistogram.record hist latency;
Printf.printf "P99: %.3f\n" (Algorithms.ExpHistogram.p99 hist)
```

### Circuit Breaker
Hystrix-style resilience pattern.
```ocaml
let cb = Algorithms.CircuitBreaker.create () in
if Algorithms.CircuitBreaker.allow cb then begin
  try do_call (); Algorithms.CircuitBreaker.record_success cb
  with _ -> Algorithms.CircuitBreaker.record_failure cb
end
```

## Multi-Domain Support (v0.4.0)

True parallel request processing using OCaml 5 domains:

```ocaml
(* Auto-detect optimal domain count *)
Server_multi.serve_multi ~domains:0 ~env server
```

Benefits:
- Linear scalability up to CPU core count
- Independent GC per domain
- SO_REUSEPORT kernel load balancing

## Roadmap

### v0.4.0 (In Progress) ✅

- [x] Multi-domain server (SO_REUSEPORT)
- [x] Buffer pooling (zero-copy)
- [x] Connection pooling
- [x] P2C load balancing
- [x] Circuit breaker
- [x] HDR Histogram metrics
- [ ] Prometheus integration

### v0.5.0 (Planned)

- [ ] Protobuf codegen plugin (PPX)
- [x] gRPC-Web support
- [ ] OpenTelemetry tracing
- [ ] Service mesh integration (Istio/Linkerd)
- [ ] io_uring backend (Linux)

## References

- [gRPC Performance Best Practices](https://grpc.io/docs/guides/performance/)
- [grpc-bench](https://github.com/LesnyRumcajs/grpc-bench) - Multi-language benchmarks
- [tonic](https://github.com/hyperium/tonic) - Rust gRPC
- [Eio](https://github.com/ocaml-multicore/eio) - OCaml effects-based IO
