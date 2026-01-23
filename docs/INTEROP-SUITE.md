# Interop Streaming Suite

This suite exercises core interop behaviors using Go/Rust clients against the OCaml gRPC server:

- Streaming (server/client/bidi)
- Cancellation (RST_STREAM on the wire)
- GOAWAY / connection close path (server shutdown)

## Automated matrix run (recommended)

Runs plaintext/TLS × identity/gzip with optional repeats. Logs are kept under `bench/`.

```
cd grpc-direct

./bench/run_interop_suite.sh --repeat 3
```

## Official gRPC interop (grpc-go client)

Runs the grpc-go interop client against the OCaml server implementation of
`grpc.testing.TestService`. This covers core unary/streaming/cancel cases.

```
cd grpc-direct

./bench/run_official_interop.sh
```

TLS (optional):

```
USE_TLS=1 CERT_FILE=tmp_tls/server.pem KEY_FILE=tmp_tls/server.key \
CA_FILE=tmp_tls/ca.pem SERVER_NAME=localhost \
./bench/run_official_interop.sh
```

Supported cases:

- empty_unary, large_unary
- client_streaming, server_streaming
- ping_pong, empty_stream
- timeout_on_sleeping_server
- cancel_after_begin, cancel_after_first_response
- unimplemented_method, unimplemented_service

Skipped (unsupported today):

- custom_metadata, status_code_and_message, special_status_message
- orca_per_rpc, orca_oob, pick_first_unary
- compute_engine_creds, service_account_creds, jwt_token_creds, per_rpc_creds,
  oauth2_auth_token, google_default_credentials, compute_engine_channel_credentials

Useful flags:

- `--plaintext-only` / `--tls-only`
- `--no-gzip` / `--gzip-only`
- `--skip-goaway`
- `--stream-count <n>` / `--cancel-after <n>`

Note: the script uses consecutive ports starting at `--port` to avoid bind reuse issues
(`main` case uses `port`, `goaway` uses `port+1`, next case starts at `port+2`).

## 1) Start OCaml server

Plaintext:

```
cd grpc-direct

dune exec --profile=release bench/interop_streaming_server.exe -- \
  --host 127.0.0.1 \
  --port 50051 \
  --stream-count 100 \
  --gzip
```

TLS (server-only):

```
cd grpc-direct

dune exec --profile=release bench/interop_streaming_server.exe -- \
  --host 127.0.0.1 \
  --port 50051 \
  --cert tmp_tls/server.pem \
  --key tmp_tls/server.key \
  --stream-count 100 \
  --gzip
```

mTLS (optional; requires client cert support):

```
cd grpc-direct

dune exec --profile=release bench/interop_streaming_server.exe -- \
  --host 127.0.0.1 \
  --port 50051 \
  --cert tmp_tls/server.pem \
  --key tmp_tls/server.key \
  --ca tmp_tls/ca.pem \
  --stream-count 100 \
  --gzip
```

## 2.1) Deadline/timeout check (grpc-timeout)

Use a long per-message delay to exceed the client deadline (Go client uses 10s).

```
cd grpc-direct

dune exec --profile=release bench/interop_streaming_server.exe -- \
  --host 127.0.0.1 \
  --port 50051 \
  --stream-count 100 \
  --stream-delay 0.2
```

## 2) Go client suite

```
cd grpc-direct/bench/go-comparison

go run -tags interop_client . \
  --addr 127.0.0.1:50051 \
  --stream-count 100 \
  --cancel-after 5 \
  --gzip
```

TLS:

```
cd grpc-direct/bench/go-comparison

go run -tags interop_client . \
  --addr 127.0.0.1:50051 \
  --tls \
  --ca ../tmp_tls/ca.pem \
  --server-name localhost \
  --gzip
```

## 3) Rust client suite

```
cd grpc-direct/bench/rust-comparison

cargo run --release --bin interop_streaming_client -- \
  --target http://127.0.0.1:50051 \
  --stream-count 100 \
  --cancel-after 5 \
  --gzip
```

TLS:

```
cd grpc-direct/bench/rust-comparison

cargo run --release --bin interop_streaming_client -- \
  --target https://127.0.0.1:50051 \
  --ca ../tmp_tls/ca.pem \
  --stream-count 100 \
  --cancel-after 5 \
  --gzip
```

## 4) GOAWAY / connection close path

Start server with shutdown timer and let clients observe connection close:

```
cd grpc-direct

dune exec --profile=release bench/interop_streaming_server.exe -- \
  --host 127.0.0.1 \
  --port 50051 \
  --shutdown-after 2
```

Then run clients with the wait flag:

```
cd grpc-direct/bench/go-comparison

go run -tags interop_client . --addr 127.0.0.1:50051 --wait-goaway
```

```
cd grpc-direct/bench/rust-comparison

cargo run --release --bin interop_streaming_client -- \
  --target http://127.0.0.1:50051 \
  --wait-goaway
```

## Notes

- Cancellation is exercised via bidi streaming with client-side cancel/drop.
- GOAWAY/close path is a graceful shutdown test; frame-level GOAWAY validation is still covered by h2spec when re-run.
