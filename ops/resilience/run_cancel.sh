#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${LOG_DIR:-$ROOT/tmp}"
PROFILE="${PROFILE:-release}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-50051}"
STREAM_COUNT="${STREAM_COUNT:-100}"
CANCEL_AFTER="${CANCEL_AFTER:-5}"

SERVER_LOG="$LOG_DIR/cancel_server.log"
CLIENT_LOG="$LOG_DIR/cancel_client.log"
SERVER_PID_FILE="$LOG_DIR/cancel_server.pid"
GO_DIR="$ROOT/bench/go-comparison"
GO_BIN="$LOG_DIR/interop_cancel_client"

mkdir -p "$LOG_DIR"

cleanup() {
  if [[ -f "$SERVER_PID_FILE" ]]; then
    kill "$(cat "$SERVER_PID_FILE")" 2>/dev/null || true
    rm -f "$SERVER_PID_FILE"
  fi
}
trap cleanup EXIT

if ! command -v go >/dev/null 2>&1; then
  echo "go not found. Install Go to run cancel test." >&2
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

echo "==> Building interop_streaming_server (profile=$PROFILE)"
dune build --profile="$PROFILE" bench/interop_streaming_server.exe

echo "==> Building go interop client"
(cd "$GO_DIR" && go build -tags=interop_client -o "$GO_BIN" .)

echo "==> Starting interop_streaming_server on $HOST:$PORT"
nohup dune exec --profile="$PROFILE" bench/interop_streaming_server.exe -- \
  --host "$HOST" --port "$PORT" \
  --stream-count "$STREAM_COUNT" \
  > "$SERVER_LOG" 2>&1 & echo $! > "$SERVER_PID_FILE"

if ! wait_for_port "$PORT"; then
  echo "Server failed to start on $HOST:$PORT (log: $SERVER_LOG)" >&2
  exit 1
fi

echo "==> Running cancel test (cancel-after=$CANCEL_AFTER)"
"$GO_BIN" --addr "$HOST:$PORT" --cancel-after "$CANCEL_AFTER" \
  --stream-count "$STREAM_COUNT" > "$CLIENT_LOG" 2>&1

echo "Cancel test completed. Logs: $SERVER_LOG, $CLIENT_LOG"
