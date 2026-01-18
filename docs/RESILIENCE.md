# Resilience Gates (grpc-eio)

This document defines resilience checks for streaming backpressure,
connection churn, and cancellation behavior.

## 1) Slow Reader (Flow Control)

Run:
```bash
./ops/resilience/run_slow_reader.sh
```

Defaults:
- STREAM_COUNT=1000
- READ_DELAY=0.05
- MAX_MESSAGES=STREAM_COUNT

Logs:
- `tmp/slow_reader_server.log`
- `tmp/slow_reader_client.log`

## 2) Connection Churn (FD leak check)

Run:
```bash
./ops/resilience/run_connection_churn.sh
```

Defaults:
- CONNECTIONS=2000
- PARALLEL=100
- FD_DELTA_ALLOWED=5 (requires `lsof`)

Logs:
- `tmp/connection_churn_server.log`
- `tmp/connection_churn_client.log`

## 3) Cancellation (Bidi cancel)

Run:
```bash
./ops/resilience/run_cancel.sh
```

Defaults:
- STREAM_COUNT=100
- CANCEL_AFTER=5

Logs:
- `tmp/cancel_server.log`
- `tmp/cancel_client.log`
