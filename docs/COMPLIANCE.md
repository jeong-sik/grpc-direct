# Compliance Gates (grpc-direct)

This document defines protocol compliance checks for HTTP/2 and gRPC.

## 1) HTTP/2 Compliance (h2spec)

Requirements:
- h2spec (Go tool)

Install:
```bash
go install github.com/summerwind/h2spec/cmd/h2spec@latest
```

Run (strict mode auto-detected when supported):
```bash
./ops/compliance/run_h2spec.sh
```

Notes:
- The helper server binds to `127.0.0.1` and uses the H2_eio stack.
- Override port or strict flags via `PORT`, `STRICT`, and `H2SPEC_ARGS`.

Logs:
- `tmp/h2spec_<ts>.log`
- `tmp/h2spec_server.log`

## 2) gRPC Interop

Core suite (Go/Rust clients):
```bash
./bench/run_interop_suite.sh --repeat 1
```

Official grpc-go client (plaintext):
```bash
./bench/run_official_interop.sh
```

Official grpc-go client (TLS):
```bash
USE_TLS=1 CERT_FILE=tmp_tls/server.pem KEY_FILE=tmp_tls/server.key \
CA_FILE=tmp_tls/ca.pem SERVER_NAME=localhost \
./bench/run_official_interop.sh
```

Logs:
- `tmp/interop_suite_*.log`
- `bench/tmp_official_interop_*.log`

See `docs/INTEROP-SUITE.md` for supported/unsupported cases.
