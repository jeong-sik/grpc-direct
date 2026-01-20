#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
LOG_DIR="${LOG_DIR:-$ROOT/tmp}"
PROFILE="${PROFILE:-release}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-50099}"

GRPC_EIO_GC_TUNE="${GRPC_EIO_GC_TUNE:-1}"
GRPC_EIO_ECHO_FAST="${GRPC_EIO_ECHO_FAST:-1}"
GRPC_EIO_ECHO_WINDOW_UPDATES="${GRPC_EIO_ECHO_WINDOW_UPDATES:-0}"

STANDARD_CONCURRENCY="${STANDARD_CONCURRENCY:-50}"
STANDARD_REQUESTS="${STANDARD_REQUESTS:-10000}"
HIGH_CONCURRENCY="${HIGH_CONCURRENCY:-200}"
HIGH_REQUESTS="${HIGH_REQUESTS:-50000}"
RUNS="${RUNS:-1}"
WARMUP_CONCURRENCY="${WARMUP_CONCURRENCY:-20}"
WARMUP_REQUESTS="${WARMUP_REQUESTS:-0}"

SERVER_LOG="$LOG_DIR/ghz_server.log"
SERVER_PID_FILE="$LOG_DIR/ghz_server.pid"
STANDARD_LOG="$LOG_DIR/ghz_standard.txt"
HIGH_LOG="$LOG_DIR/ghz_high.txt"

mkdir -p "$LOG_DIR"

cleanup() {
  if [[ -f "$SERVER_PID_FILE" ]]; then
    kill "$(cat "$SERVER_PID_FILE")" 2>/dev/null || true
    rm -f "$SERVER_PID_FILE"
  fi
}
trap cleanup EXIT

if ! command -v ghz >/dev/null 2>&1; then
  echo "ghz not found. Install via: go install github.com/bojand/ghz/cmd/ghz@latest" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found. Install Python 3 to run perf checks." >&2
  exit 1
fi

wait_for_port() {
  local port="$1"
  local retries=50
  local i=0

  if command -v nc >/dev/null 2>&1; then
    while ! nc -z "$HOST" "$port" >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -ge "$retries" ]; then
        return 1
      fi
      sleep 0.1
    done
  else
    while ! python3 - <<PY >/dev/null 2>&1
import socket
host = "$HOST"
port = int("$port")
try:
    with socket.create_connection((host, port), timeout=0.2):
        pass
except Exception:
    raise SystemExit(1)
PY
    do
      i=$((i + 1))
      if [ "$i" -ge "$retries" ]; then
        return 1
      fi
      sleep 0.1
    done
  fi
}

cd "$ROOT"

echo "==> Building h2_lite echo_server (profile=$PROFILE)"
dune build --root "$ROOT" --profile="$PROFILE" lib/grpc_eio/h2_lite/echo_server.exe

if [[ "$RUNS" -le 1 ]]; then
  echo "==> Starting h2_lite echo_server on $HOST:$PORT"
  echo "==> Env: GRPC_EIO_GC_TUNE=$GRPC_EIO_GC_TUNE GRPC_EIO_ECHO_FAST=$GRPC_EIO_ECHO_FAST GRPC_EIO_ECHO_WINDOW_UPDATES=$GRPC_EIO_ECHO_WINDOW_UPDATES"
  GRPC_EIO_GC_TUNE="$GRPC_EIO_GC_TUNE" \
  GRPC_EIO_ECHO_FAST="$GRPC_EIO_ECHO_FAST" \
  GRPC_EIO_ECHO_WINDOW_UPDATES="$GRPC_EIO_ECHO_WINDOW_UPDATES" \
  nohup dune exec --root "$ROOT" --profile="$PROFILE" lib/grpc_eio/h2_lite/echo_server.exe -- "$PORT" \
    > "$SERVER_LOG" 2>&1 & echo $! > "$SERVER_PID_FILE"

  if ! wait_for_port "$PORT"; then
    echo "Server failed to start on $HOST:$PORT (log: $SERVER_LOG)" >&2
    exit 1
  fi

  if [[ "$WARMUP_REQUESTS" -gt 0 ]]; then
    echo "==> Running warmup ghz"
    ghz --insecure --proto bench/go-comparison/echo.proto \
      --call echo.EchoService/Echo \
      -d '{"message":"hello"}' -c "$WARMUP_CONCURRENCY" -n "$WARMUP_REQUESTS" \
      "$HOST:$PORT" >/dev/null
  fi

  echo "==> Running standard ghz"
  ghz --insecure --proto bench/go-comparison/echo.proto \
    --call echo.EchoService/Echo \
    -d '{"message":"hello"}' -c "$STANDARD_CONCURRENCY" -n "$STANDARD_REQUESTS" \
    "$HOST:$PORT" | tee "$STANDARD_LOG"

  python3 ops/perf/check_ghz.py --mode standard --file "$STANDARD_LOG"

  echo "==> Running high ghz"
  ghz --insecure --proto bench/go-comparison/echo.proto \
    --call echo.EchoService/Echo \
    -d '{"message":"hello"}' -c "$HIGH_CONCURRENCY" -n "$HIGH_REQUESTS" \
    "$HOST:$PORT" | tee "$HIGH_LOG"

  python3 ops/perf/check_ghz.py --mode high --file "$HIGH_LOG"

  echo "ghz baseline completed. Logs: $STANDARD_LOG, $HIGH_LOG"
  exit 0
fi

BASE_LOG="$LOG_DIR/ghz_runs_$(date +%Y%m%d_%H%M%S)"
SUMMARY_FILE="$BASE_LOG/summary.txt"
mkdir -p "$BASE_LOG"

{
  echo "Run timestamp: $(date -Iseconds)"
  echo "ROOT=$ROOT"
  echo "ENV: GRPC_EIO_GC_TUNE=$GRPC_EIO_GC_TUNE GRPC_EIO_ECHO_FAST=$GRPC_EIO_ECHO_FAST GRPC_EIO_ECHO_WINDOW_UPDATES=$GRPC_EIO_ECHO_WINDOW_UPDATES"
  echo "PROFILE=$PROFILE HOST=$HOST PORT=$PORT"
  echo "STANDARD: c=$STANDARD_CONCURRENCY n=$STANDARD_REQUESTS"
  echo "HIGH: c=$HIGH_CONCURRENCY n=$HIGH_REQUESTS"
  echo "WARMUP: c=$WARMUP_CONCURRENCY n=$WARMUP_REQUESTS"
  echo
} > "$SUMMARY_FILE"

for i in $(seq 1 "$RUNS"); do
  RUN_DIR="$BASE_LOG/run_$i"
  mkdir -p "$RUN_DIR"
  SERVER_LOG="$RUN_DIR/ghz_server.log"
  SERVER_PID_FILE="$RUN_DIR/ghz_server.pid"
  STANDARD_LOG="$RUN_DIR/ghz_standard.txt"
  HIGH_LOG="$RUN_DIR/ghz_high.txt"

  echo "==> Run $i/$RUNS: starting server"
  GRPC_EIO_GC_TUNE="$GRPC_EIO_GC_TUNE" \
  GRPC_EIO_ECHO_FAST="$GRPC_EIO_ECHO_FAST" \
  GRPC_EIO_ECHO_WINDOW_UPDATES="$GRPC_EIO_ECHO_WINDOW_UPDATES" \
  nohup dune exec --root "$ROOT" --profile="$PROFILE" lib/grpc_eio/h2_lite/echo_server.exe -- "$PORT" \
    > "$SERVER_LOG" 2>&1 & echo $! > "$SERVER_PID_FILE"

  if ! wait_for_port "$PORT"; then
    echo "Run $i: server failed to start on $HOST:$PORT (log: $SERVER_LOG)" >> "$SUMMARY_FILE"
    cleanup
    continue
  fi

  if [[ "$WARMUP_REQUESTS" -gt 0 ]]; then
    echo "==> Run $i: warmup"
    ghz --insecure --proto bench/go-comparison/echo.proto \
      --call echo.EchoService/Echo \
      -d '{"message":"hello"}' -c "$WARMUP_CONCURRENCY" -n "$WARMUP_REQUESTS" \
      "$HOST:$PORT" >/dev/null
  fi

  echo "==> Run $i: standard"
  ghz --insecure --proto bench/go-comparison/echo.proto \
    --call echo.EchoService/Echo \
    -d '{"message":"hello"}' -c "$STANDARD_CONCURRENCY" -n "$STANDARD_REQUESTS" \
    "$HOST:$PORT" | tee "$STANDARD_LOG" >/dev/null

  if python3 ops/perf/check_ghz.py --mode standard --file "$STANDARD_LOG"; then
    STANDARD_RESULT="PASS"
  else
    STANDARD_RESULT="FAIL"
  fi

  echo "==> Run $i: high"
  ghz --insecure --proto bench/go-comparison/echo.proto \
    --call echo.EchoService/Echo \
    -d '{"message":"hello"}' -c "$HIGH_CONCURRENCY" -n "$HIGH_REQUESTS" \
    "$HOST:$PORT" | tee "$HIGH_LOG" >/dev/null

  if python3 ops/perf/check_ghz.py --mode high --file "$HIGH_LOG"; then
    HIGH_RESULT="PASS"
  else
    HIGH_RESULT="FAIL"
  fi

  echo "Run $i: standard=$STANDARD_RESULT high=$HIGH_RESULT" >> "$SUMMARY_FILE"
  cleanup
  sleep 0.3
done

echo "ghz baseline completed. Summary: $SUMMARY_FILE"
