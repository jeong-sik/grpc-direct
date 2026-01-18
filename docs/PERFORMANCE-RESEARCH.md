# H2_lite Performance Research: 76% of grpc-go (final benchmark)

## Current Status (Updated 2026-01-12, FINAL)

**Fair comparison (both warm, same machine, alternating runs):**
- **h2_lite TURBO**: ~33,500 RPS median
- **grpc-go**: ~43,800 RPS median
- **RPS Ratio**: **76%** of grpc-go
- **Improvement**: +16% from initial 60%

### Benchmark Methodology
- Both servers warmed up before measurement
- 3 alternating runs each (h2_lite → grpc-go → h2_lite → ...)
- Same machine, same benchmark tool (ghz)
- 50 concurrent connections, 10,000 requests per run

⚠️ **Previous claim of 100% was incorrect** - grpc-go wasn't properly warmed up.

## Optimizations Applied
| Change | Effect | Server |
|--------|--------|--------|
| TCP_NODELAY | Enabled (like grpc-go default) | Both |
| SO_SNDBUF/SO_RCVBUF | 64KB (increased from default) | Both |
| WINDOW_UPDATE batching | 32KB threshold | Both |
| -O3 compiler flags | Minimal improvement | Both |
| HPACK decoding removal | No improvement (turbo) | Turbo only |

## Failed Optimizations (Learnings)
| Change | Expected | Actual | Why |
|--------|----------|--------|-----|
| Buffer Pool for payload | Reduce GC | **-15%** | OCaml GC efficient for short-lived objects |
| Piggyback WINDOW_UPDATE | Reduce syscall | **-8%** | Rare calls, conditional overhead dominates |
| 128KB WINDOW_UPDATE batch | Better throughput | **-14%** | Hurt small message latency |
| HPACK removal (turbo) | +10-20% | **0%** | HPACK is NOT the bottleneck |
| -O3 compiler flags | +5-10% | **~0%** | Code already well-optimized |

## Key Discovery: HPACK is NOT the Bottleneck

**Experiment**: Created `echo_server_turbo.ml` that:
- Skips ALL HPACK decoding
- No stream state management
- Direct gRPC message handling
- Inline frame processing

**Result**: Same performance as regular echo_server (~33K RPS)

**Conclusion**: The performance gap is NOT in:
- HPACK encoding/decoding
- Stream multiplexing overhead
- Frame parsing logic

The gap IS in:
- **Go runtime vs OCaml/Eio runtime** (scheduler, memory allocator)
- **System call batching** (writev patterns)
- **Platform-specific optimizations** (io_uring vs kqueue)

## Remaining Gap Analysis
grpc-go is **24% faster** due to:
1. **Loopy Writer**: Dedicated goroutine batches frames (not yet implemented)
2. **BDP-based flow control**: Dynamic window sizing
3. **sync.Pool**: Aggressive buffer reuse
4. **Go runtime**: Highly optimized scheduler vs OCaml 5 Eio

## Key Discoveries

### 1. grpc-go Performance Secrets

**Loopy Writer Architecture** ([source](https://github.com/grpc/grpc-go/blob/master/internal/transport/controlbuf.go))
- Dedicated writer goroutine that batches frames
- Round-robin stream selection for fairness
- Batches multiple frames into single syscall flush
- Control buffer queues frames, loopy writer processes them asynchronously

**BDP-Based Dynamic Flow Control** ([gRPC blog](https://grpc.io/blog/grpc-go-perf-improvements/))
- Adjusts window size based on Bandwidth Delay Product
- Keeps running average of RTTs
- Prevents buffer bloat while maximizing throughput

**Piggyback Window Updates**
- Combines stream + connection level WINDOW_UPDATE in single flush
- Reduces syscall overhead significantly

**Buffer Pool with sync.Pool**
- Per-size-class pooling (powers of 2)
- Reuses buffers across requests
- Reduces GC pressure

### 2. OCaml 5 Multicore Insights

**From Eio docs** ([multicore.md](https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md))
- Jobs < 2-5ms don't benefit from parallelization (our echo is ~1ms!)
- Use persistent domain pools (Eio.Executor_pool)
- Minimize cross-domain memory access
- Saturn library for lock-free data structures

**Why multi-domain hurt us**:
- Echo requests are too short (~1ms) for domain overhead
- Cross-domain coordination adds latency
- Single domain with efficient fiber switching is better for short requests

### 3. Jane Street OxCaml Techniques

**Unboxed Types** ([tech talk](https://www.janestreet.com/tech-talks/making-ocaml-safe-for-performance-engineering/))
- `int32#`, `float#` - raw bits, no heap allocation
- "Int64s in OCaml are a three-word allocated block on the heap"
- Eliminates GC pressure for numeric types

**Stack Allocation with `local` mode**
- Short-lived data on stack, not heap
- Automatic cleanup without GC
- Type system ensures no escaping

**Cache-Friendly Layouts**
- Pointer-based structures defeat prefetching
- Tabular layouts improve cache line utilization

### 4. Rust Tonic Architecture

**Key Components** ([GitHub](https://github.com/hyperium/tonic))
- Built on hyper (high-perf HTTP/2) + tokio (async runtime)
- Tower middleware for layered architecture
- Zero-cost abstractions compile away

## Actionable Improvements for h2_lite

### Priority 1: Loopy Writer Pattern (High Impact)
```ocaml
(* Current: synchronous write per frame *)
let write_frame t frame = Eio.Flow.write t.flow [...]

(* Proposed: async batched writer *)
type write_queue = Frame.t Eio.Stream.t

let loopy_writer t queue =
  while true do
    (* Collect all pending frames *)
    let frames = drain_queue queue in
    (* Batch into single syscall *)
    let iovecs = List.concat_map frame_to_cstructs frames in
    Eio.Flow.write t.flow iovecs
  done
```

### Priority 2: Read-Side Buffer Reuse (Medium Impact)
```ocaml
(* Current: allocate new buffer per frame *)
let payload_copy = Cstruct.create len in

(* Proposed: pool-based allocation *)
let payload_copy = Buffer_pool.acquire ~size:len in
(* ... use ... *)
(* Caller must release when done *)
```

### Priority 3: Avoid Frame-Level Allocation (Medium Impact)
- Pre-allocate Frame.t records
- Use mutable fields instead of creating new records
- Consider arena allocation for request lifetime

### Priority 4: Linux io_uring Backend (Platform-Specific)
- macOS kqueue has inherent limitations
- Test on Linux for true performance comparison
- io_uring allows batched syscalls

## Performance Comparison Context

| Implementation | RPS | % of grpc-go | Notes |
|---------------|-----|--------------|-------|
| grpc-go | 43,800 | 100% | Loopy writer, sync.Pool, BDP flow control |
| **h2_lite turbo** | **33,500** | **76%** | Zero HPACK, minimal overhead |
| h2_lite standard | 33,000 | 75% | Full RFC 7540/7541 compliance |
| tonic (Rust) | ~45,000* | ~103% | Zero-cost, hyper backend |

*Estimated based on typical benchmarks

### Server Variants

| Server | Description | Use Case |
|--------|-------------|----------|
| `echo_server.ml` | Full H2 + HPACK + flow control | Production |
| `echo_server_turbo.ml` | Zero HPACK, minimal state | Benchmarking |
| `echo_server_multi.ml` | Multi-domain (experimental) | High concurrency |

## Next Steps

### Recommended (High Impact)
1. **Test on Linux with io_uring** - macOS kqueue has inherent limitations
2. **Profile with `magic-trace`** - Find exact syscall patterns and hotspots
3. **Explore Eio.Executor_pool** - For CPU-bound workloads (not echo)

### Deferred (Low Impact for Echo)
4. **Loopy Writer pattern** - Minimal benefit for single request-response
5. **OxCaml unboxed types** - Requires compiler support

### Conclusion

At **76% of grpc-go**, h2_lite achieves respectable performance for a pure OCaml implementation.
The remaining gap is primarily due to:
- Go's highly optimized runtime (goroutine scheduler, GC)
- Go's mature HTTP/2 ecosystem (10+ years of optimization)
- Platform-specific optimizations (io_uring on Linux)

For production use cases requiring maximum performance, consider:
- Running on Linux (not macOS)
- Using connection pooling
- Avoiding unnecessary HPACK dynamic table updates

## Sources

- [gRPC-Go Performance Improvements](https://grpc.io/blog/grpc-go-perf-improvements/)
- [gRPC Optimization Part 2](https://grpc.io/blog/optimizing-grpc-part-2/)
- [Eio Multicore Guide](https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md)
- [Jane Street OxCaml](https://blog.janestreet.com/introducing-oxcaml/)
- [Making OCaml Safe for Performance Engineering](https://www.janestreet.com/tech-talks/making-ocaml-safe-for-performance-engineering/)
- [grpc-go controlbuf.go](https://github.com/grpc/grpc-go/blob/master/internal/transport/controlbuf.go)
- [Tonic GitHub](https://github.com/hyperium/tonic)
