# Performance Baseline (grpc-eio)

This document defines the grpc-eio performance baseline and regression
thresholds for unary echo on localhost.

## Environment

- macOS Darwin 25.2.0, Apple Silicon (M-series, 16 domains available)
- ghz 0.121.0 (client)
- OCaml 5.x + Eio
- Echo service with minimal payload (h2_lite backend)
- Date: 2026-01-15

## Test Definitions

Standard test:
- Concurrency: 50
- Requests: 10,000
- Payload: `{"message":"hello"}`
- Transport: plaintext, localhost

High concurrency test:
- Concurrency: 200
- Requests: 50,000
- Payload: `{"message":"hello"}`
- Transport: plaintext, localhost

## Baseline Results (grpc-eio)

Standard (50c / 10k):
- RPS: 34,644.44
- P50: 1.31 ms
- P95: 1.66 ms
- P99: 1.86 ms
- Error rate: 0%

High (200c / 50k):
- RPS: 38,903.48
- P50: 5.07 ms
- P95: 5.54 ms
- P99: 5.72 ms
- Error rate: 0%

Raw logs:
- `tmp/ghz_standard.txt`
- `tmp/ghz_high.txt`

## Regression Thresholds

Standard (50c / 10k):
- RPS >= 31,180.00 (>= 90% of baseline)
- P95 <= 1.99 ms (+20%)
- P99 <= 2.23 ms (+20%)
- Error rate <= 0.1%

High (200c / 50k):
- RPS >= 35,013.13 (>= 90% of baseline)
- P95 <= 6.65 ms (+20%)
- P99 <= 6.86 ms (+20%)
- Error rate <= 0.1%

## Evaluation Procedure

- Run Standard + High tests 3 times each.
- Use the median RPS and P99 for comparison.
- Mark a run invalid if error rate > 0.1% or if the server logs show resets/timeouts.
- Keep the machine idle and note OS/ghz/commit in the log header.

## Automation

```bash
./ops/perf/run_ghz_baseline.sh
```

This script writes `tmp/ghz_standard.txt` and `tmp/ghz_high.txt` and validates
thresholds via `ops/perf/check_ghz.py`.

## Re-run (example)

```bash
# grpc-eio server (h2_lite backend)
dune exec --profile=release lib/grpc_eio/h2_lite/echo_server.exe -- 50099

# Standard test
ghz --insecure --proto bench/go-comparison/echo.proto \
  --call echo.EchoService/Echo \
  -d '{"message":"hello"}' -c 50 -n 10000 \
  127.0.0.1:50099

# High concurrency test
ghz --insecure --proto bench/go-comparison/echo.proto \
  --call echo.EchoService/Echo \
  -d '{"message":"hello"}' -c 200 -n 50000 \
  127.0.0.1:50099
```

Notes:
- Update baselines when hardware/runtime changes.
- Keep the ghz client version consistent to avoid noise.
