# Performance Baseline (grpc-eio) — Draft

> Note: Public benchmarks are not published yet.  
> This document keeps the procedure, but omits numbers.

This document defines the grpc-eio performance baseline and regression
thresholds for unary echo on localhost.

## Environment (example)

- macOS Darwin 25.2.0, Apple Silicon (M-series, 16 domains available)
- ghz 0.121.0 (client)
- OCaml 5.x + Eio
- Echo service with minimal payload (h2_lite backend)
- Date: TBD (run locally)

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

## Baseline Results

Not published yet (TBD).

Raw logs (local runs):
- `tmp/ghz_standard.txt`
- `tmp/ghz_high.txt`

## Regression Thresholds

Not published yet (TBD).

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
