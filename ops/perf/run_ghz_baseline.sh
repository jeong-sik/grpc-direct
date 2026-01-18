#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${LOG_DIR:-$ROOT/tmp}"
PROFILE="${PROFILE:-release}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-50099}"

STANDARD_CONCURRENCY="${STANDARD_CONCURRENCY:-50}"
STANDARD_REQUESTS="${STANDARD_REQUESTS:-10000}"
HIGH_CONCURRENCY="${HIGH_CONCURRENCY:-200}"
HIGH_REQUESTS="${HIGH_REQUESTS:-50000}"

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
    sleep 1
  fi
}

cd "$ROOT"

echo "==> Building h2_lite echo_server (profile=$PROFILE)"
dune build --profile="$PROFILE" lib/grpc_eio/h2_lite/echo_server.exe

echo "==> Starting h2_lite echo_server on $HOST:$PORT"
nohup dune exec --profile="$PROFILE" lib/grpc_eio/h2_lite/echo_server.exe -- "$PORT" \
  > "$SERVER_LOG" 2>&1 & echo $! > "$SERVER_PID_FILE"

if ! wait_for_port "$PORT"; then
  echo "Server failed to start on $HOST:$PORT (log: $SERVER_LOG)" >&2
  exit 1
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
