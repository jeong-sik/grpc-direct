# grpc-direct v2: Pure RFC Implementation Design

## Overview

순수 RFC 스펙 기반 OCaml gRPC 구현. 외부 C/Rust 의존 없이 RFC 직접 구현.

## Reference Specifications

| Spec | Description | Status |
|------|-------------|--------|
| RFC 7540 | HTTP/2 Protocol | ✅ Core frames/state/flow control + SETTINGS/GOAWAY/PING; ⚠️ priority scheduling partial |
| RFC 7541 | HPACK Compression | ✅ Dynamic table + Huffman encode/decode |
| gRPC over HTTP/2 | Message framing + metadata | ✅ Implemented (timeouts, compression negotiation) |
| gRPC-Web | HTTP/1.1 + WS bridge | ✅ Implemented (binary/text, trailers-in-body) |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    gRPC Service Layer                   │
│   (Protobuf encoding, service definitions, interceptors)│
├─────────────────────────────────────────────────────────┤
│                   gRPC Transport Layer                  │
│   (Message framing, metadata, status codes)             │
├─────────────────────────────────────────────────────────┤
│                    HTTP/2 Layer                         │
│   ┌─────────────┬─────────────┬─────────────────────┐   │
│   │   Streams   │    HPACK    │   Flow Control      │   │
│   │   Manager   │   Encoder   │   (per-stream)      │   │
│   └─────────────┴─────────────┴─────────────────────┘   │
├─────────────────────────────────────────────────────────┤
│                  Frame Layer (RFC 7540)                 │
│   (Frame parsing, serialization, validation)            │
├─────────────────────────────────────────────────────────┤
│                    Transport I/O                        │
│   (Eio.Flow, TLS via OCaml-TLS or direct socket)       │
└─────────────────────────────────────────────────────────┘
```

gRPC-Web bridge:
- HTTP/1.1 entrypoint with CORS
- Binary/text mode (base64)
- Trailers encoded in body (0x80 frame)

## Module Structure

```
lib/grpc_eio/
├── h2_lite/
│   ├── frame.ml              # RFC 7540 §4 - Frame format
│   ├── hpack.ml              # RFC 7541 - Header compression
│   ├── stream.ml             # RFC 7540 §5 - Stream states
│   ├── flow_control.ml       # RFC 7540 §5.2 - Flow control
│   ├── priority_scheduler.ml # RFC 7540 §5.3 - Priority (partial)
│   └── connection.ml         # Connection + SETTINGS/GOAWAY/PING
├── http2_handler.ml          # gRPC response + trailers helpers
├── server.ml                 # gRPC server
├── client.ml                 # gRPC client
├── grpc_web.ml               # gRPC-Web framing + trailers
├── grpc_web_server.ml        # gRPC-Web HTTP/1.1 bridge
├── grpc_web_ws_server.ml     # gRPC-Web WebSocket bridge
└── grpc_web_client.ml        # gRPC-Web client

lib/grpc_core/
├── message.ml            # gRPC 5-byte message framing
├── status.ml             # gRPC status codes
├── codec.ml              # Compression codecs
└── timeout.ml            # grpc-timeout parsing
```

## Performance Baselines

최신 결과는 `bench/README.md`의 `Latest Results` 섹션에 기록합니다.

## RFC Coverage Checklist (2026-01-18)

### RFC 7540 (HTTP/2)
- ✅ Frame parsing/serialization: DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE, PING, GOAWAY, WINDOW_UPDATE, CONTINUATION (`lib/grpc_eio/h2_lite/frame.ml`)
- ✅ Stream state machine (idle/open/half-closed/closed) (`lib/grpc_eio/h2_lite/stream.ml`)
- ✅ Flow control (connection + per-stream windows, WINDOW_UPDATE validation) (`lib/grpc_eio/h2_lite/flow_control.ml`)
- ✅ SETTINGS validation + application (max frame size, header list size) (`lib/grpc_eio/h2_lite/connection.ml`, `lib/grpc_eio/h2_lite/h2_lite.ml`)
- ✅ CONTINUATION reassembly for header blocks (`lib/grpc_eio/h2_lite/connection.ml`)
- ⚠️ Priority: parsing + weighted RR scheduling; dependency tree not enforced (`lib/grpc_eio/h2_lite/priority_scheduler.ml`)
- ⚠️ Server push: protocol support present; disabled by default for gRPC (`lib/grpc_eio/h2_lite/connection.ml`, `lib/grpc_eio/h2_lite/h2_lite.ml`)

### RFC 7541 (HPACK)
- ✅ Static + dynamic tables with eviction + size updates (`lib/grpc_eio/h2_lite/hpack.ml`)
- ✅ Huffman encode/decode with auto selection (`lib/grpc_eio/h2_lite/hpack.ml`)
- ✅ Header list size enforcement via SETTINGS_MAX_HEADER_LIST_SIZE (`lib/grpc_eio/h2_lite/h2_lite.ml`)

### gRPC over HTTP/2
- ✅ 5-byte message framing + compression (`lib/grpc_core/message.ml`)
- ✅ Required headers/metadata (content-type, te: trailers, grpc-encoding, grpc-accept-encoding, grpc-timeout) (`lib/grpc_eio/client.ml`, `lib/grpc_eio/server.ml`)
- ✅ Status + trailers handling with percent-encoding (`lib/grpc_eio/http2_handler.ml`, `lib/grpc_eio/server.ml`)
- ✅ Unary + streaming request paths (`lib/grpc_eio/client.ml`, `lib/grpc_eio/server.ml`)

### gRPC-Web
- ✅ HTTP/1.1 bridge + binary/text + trailers-in-body (0x80 frame) (`lib/grpc_eio/grpc_web.ml`, `lib/grpc_eio/grpc_web_server.ml`)
- ✅ WebSocket bridge (grpc-websockets subprotocol) (`lib/grpc_eio/grpc_web_ws_server.ml`)

## Implementation Plan

### Phase 1: Core HTTP/2 (Week 1)
- [x] HPACK with dynamic table
- [x] Huffman decode + encode (auto when smaller)
- [x] Stream state machine
- [x] Proper flow control
- [x] SETTINGS negotiation
- [x] Priority (dependency/weight parsing)
- [x] PUSH_PROMISE frame support

### Phase 2: gRPC Layer (Week 2)
- [x] Metadata handling
- [x] Status codes
- [x] Deadline propagation
- [x] Compression support

### Phase 3: Performance (Week 3)
- [x] Zero-copy where possible
- [x] Connection pooling
- [x] Benchmark & tune

## Current h2_lite Analysis

Strengths:
- RFC 7540/7541 core + HPACK dynamic table + Huffman encode/decode
- Stream state machine + flow control + GOAWAY/RST handling
- gRPC framing (headers/trailers) + streaming support

Weaknesses (remaining gaps vs grpc-go):
1. **Priority scheduling is advisory**: Weighted RR uses weights; dependency is parsed but not enforced
2. **Server push is optional**: Implemented at protocol level, not used in gRPC
3. **Write coalescing limits**: Still behind grpc-go/tonic on loopy writer batching

## References

- [RFC 7540 - HTTP/2](https://httpwg.org/specs/rfc7540.html)
- [RFC 7541 - HPACK](https://httpwg.org/specs/rfc7541.html)
- [gRPC over HTTP/2](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)
- [grpc-go source](https://github.com/grpc/grpc-go)
