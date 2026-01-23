# Production Readiness Checklist (Draft)

> ⚠️ Experimental project  
> This is a **checklist**, not a claim of readiness.  
> Public benchmarks and evidence are not published yet.

Date: 2026-01-18 (last internal review)

Scope: RFC 7540/7541 + gRPC core + gRPC-Web (gateway path for client streaming/bidi).

## 1) Interop Suite (Go/Rust clients vs OCaml server)

Run:
```
./bench/run_interop_suite.sh --repeat 1
```

## 2) Official gRPC Interop (grpc-go client)

Plaintext:
```
./bench/run_official_interop.sh
```

TLS:
```
USE_TLS=1 CERT_FILE=tmp_tls/server.pem KEY_FILE=tmp_tls/server.key \
CA_FILE=tmp_tls/ca.pem SERVER_NAME=localhost \
./bench/run_official_interop.sh
```

Known skips (unsupported by design):
- custom_metadata, status_code_and_message, special_status_message
- orca_per_rpc, orca_oob, pick_first_unary
- compute_engine_creds, service_account_creds, jwt_token_creds, per_rpc_creds
- oauth2_auth_token, google_default_credentials, compute_engine_channel_credentials

## 3) Observability Verification (Prometheus)

- Alerts: `ops/prometheus/alerts.yml`
- Metrics endpoints: `ops/prometheus/`

## 4) Performance Baseline (ghz)

Not published yet. Keep results in private logs only.

Automation:
```
./ops/perf/run_ghz_baseline.sh
```

## 5) Soak (low load)

Not published yet. Keep results in private logs only.

Run:
```
CONCURRENCY=10 DURATION_PER_RUN=10s DURATION_SECONDS=86400 \
./ops/soak/run_soak.sh
```

## 6) HTTP/2 Compliance (h2spec)

Run:
```
./ops/compliance/run_h2spec.sh
```

## 7) Resilience Gates

Slow reader (flow control):
```
./ops/resilience/run_slow_reader.sh
```

Connection churn (FD leak check):
```
./ops/resilience/run_connection_churn.sh
```

Cancellation (bidi cancel):
```
./ops/resilience/run_cancel.sh
```

## Evidence Policy (Public Repo)

- Do not commit raw benchmark logs or results.
- Keep internal evidence in private storage.
