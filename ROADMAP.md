# Roadmap

grpc-direct development roadmap. Feedback welcome via GitHub Issues.

Current package version: **v0.1.0** (experimental).

## v0.2.0 (Planned)

**Theme**: Foundation + Security

- [x] Core gRPC protocol (unary, streaming)
- [x] gzip + identity compression
- [x] Interceptor chain
- [x] **Native TLS** via tls-eio
- [x] Benchmark harness (results not published)
- [x] Friendly error messages

## v0.3.0 (Planned)

**Theme**: Observability + Resilience

- [ ] Health check endpoint (gRPC Health Checking Protocol)
- [ ] Server reflection API
- [ ] Retry policy with exponential backoff
- [ ] Deadline propagation
- [ ] Metrics hooks (for Prometheus/OpenTelemetry)

## v0.4.0 (Planned)

**Theme**: Performance

- [ ] zstd compression codec
- [ ] Connection pooling (client)
- [ ] Keep-alive pings
- [ ] Flow control tuning

## v1.0.0

**Theme**: Production Readiness (Draft)

- [ ] Load balancing (round-robin, weighted)
- [ ] Service discovery integration
- [ ] Graceful shutdown
- [ ] Rate limiting
- [ ] Full gRPC spec compliance audit

---

## Deferred (Community Interest)

These may be added based on demand:

- **Odersky**: Phantom types for timeout units
- **Knuth**: Exhaustive API documentation
- **Fuller**: Streaming certificate loading
- **Carmack**: SIMD-optimized parsing (requires C bindings)

## Contributing

1. Pick an item from the roadmap
2. Open an issue to discuss approach
3. Submit PR with tests

## Non-Goals

- Lwt/Async support (use ocaml-grpc instead)
- HTTP/1.1 fallback (H2 only)
- Protobuf runtime (bring your own)
