# H2_lite Performance Research (Draft)

> Note: Public benchmarks are not published yet.  
> This document lists ideas and methodology only; numbers are intentionally omitted.

## Scope

- Capture performance hypotheses and experiment ideas for h2_lite.
- Avoid publishing benchmark claims in the public repo.

## Areas of Interest

- **Writer batching** (loopy writer / write coalescing)
- **Flow control tuning** (WINDOW_UPDATE batching, initial window sizing)
- **Buffer reuse** (pooling to reduce allocations)
- **Runtime effects** (scheduler behavior, GC pressure)
- **Multi-domain trade-offs** (parallelism vs coordination cost)
- **Platform differences** (macOS kqueue vs Linux io_uring)

## Next Steps (Private Runs)

1. Run local benchmarks and keep raw logs in a private scratch area.
2. Validate on Linux with io_uring for realistic throughput baselines.
3. Profile with `magic-trace` or equivalent to identify hot paths.

## References

- [gRPC-Go Performance Improvements](https://grpc.io/blog/grpc-go-perf-improvements/)
- [gRPC Optimization Part 2](https://grpc.io/blog/optimizing-grpc-part-2/)
- [Eio Multicore Guide](https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md)
- [Jane Street OxCaml](https://blog.janestreet.com/introducing-oxcaml/)
- [Making OCaml Safe for Performance Engineering](https://www.janestreet.com/tech-talks/making-ocaml-safe-for-performance-engineering/)
- [grpc-go controlbuf.go](https://github.com/grpc/grpc-go/blob/master/internal/transport/controlbuf.go)
- [Tonic GitHub](https://github.com/hyperium/tonic)
