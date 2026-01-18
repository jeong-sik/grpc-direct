#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${LOG_DIR:-$ROOT/tmp}"
PROFILE="${PROFILE:-release}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-50051}"
CONNECTIONS="${CONNECTIONS:-2000}"
PARALLEL="${PARALLEL:-100}"
FD_DELTA_ALLOWED="${FD_DELTA_ALLOWED:-5}"

SERVER_LOG="$LOG_DIR/connection_churn_server.log"
CLIENT_LOG="$LOG_DIR/connection_churn_client.log"
SERVER_PID_FILE="$LOG_DIR/connection_churn_server.pid"

mkdir -p "$LOG_DIR"

cleanup() {
  if [[ -f "$SERVER_PID_FILE" ]]; then
    kill "$(cat "$SERVER_PID_FILE")" 2>/dev/null || true
    rm -f "$SERVER_PID_FILE"
  fi
}
trap cleanup EXIT

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

fd_count() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -p "$1" 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}

cd "$ROOT"

echo "==> Building interop_streaming_server + connection_churn_client (profile=$PROFILE)"
dune build --profile="$PROFILE" \
  bench/interop_streaming_server.exe \
  bench/connection_churn_client.exe

echo "==> Starting interop_streaming_server on $HOST:$PORT"
nohup dune exec --profile="$PROFILE" bench/interop_streaming_server.exe -- \
  --host "$HOST" --port "$PORT" \
  > "$SERVER_LOG" 2>&1 & echo $! > "$SERVER_PID_FILE"

if ! wait_for_port "$PORT"; then
  echo "Server failed to start on $HOST:$PORT (log: $SERVER_LOG)" >&2
  exit 1
fi

SERVER_PID="$(cat "$SERVER_PID_FILE")"
FD_BEFORE="$(fd_count "$SERVER_PID")"

echo "==> Running connection churn (connections=$CONNECTIONS parallel=$PARALLEL)"
dune exec --profile="$PROFILE" bench/connection_churn_client.exe -- \
  --target "http://$HOST:$PORT" \
  --connections "$CONNECTIONS" \
  --parallel "$PARALLEL" \
  > "$CLIENT_LOG" 2>&1

FD_AFTER="$(fd_count "$SERVER_PID")"
DELTA=$((FD_AFTER - FD_BEFORE))

if command -v lsof >/dev/null 2>&1; then
  printf "FD baseline=%s after=%s delta=%s (allowed=%s)\n" "$FD_BEFORE" "$FD_AFTER" "$DELTA" "$FD_DELTA_ALLOWED"
  if [ "$DELTA" -gt "$FD_DELTA_ALLOWED" ]; then
    echo "FD leak suspected (delta > allowed)." >&2
    exit 1
  fi
else
  echo "lsof not found; skipping FD leak check."
fi

echo "Connection churn completed. Logs: $SERVER_LOG, $CLIENT_LOG"
