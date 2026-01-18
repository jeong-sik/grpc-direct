#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${LOG_DIR:-$ROOT/tmp}"
PROFILE="${PROFILE:-release}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-50051}"
STREAM_COUNT="${STREAM_COUNT:-1000}"
STREAM_DELAY="${STREAM_DELAY:-0}"
READ_DELAY="${READ_DELAY:-0.05}"
MAX_MESSAGES="${MAX_MESSAGES:-$STREAM_COUNT}"

SERVER_LOG="$LOG_DIR/slow_reader_server.log"
CLIENT_LOG="$LOG_DIR/slow_reader_client.log"
SERVER_PID_FILE="$LOG_DIR/slow_reader_server.pid"

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

cd "$ROOT"

echo "==> Building interop_streaming_server + slow_reader_client (profile=$PROFILE)"
dune build --profile="$PROFILE" \
  bench/interop_streaming_server.exe \
  bench/slow_reader_client.exe

echo "==> Starting interop_streaming_server on $HOST:$PORT"
nohup dune exec --profile="$PROFILE" bench/interop_streaming_server.exe -- \
  --host "$HOST" --port "$PORT" \
  --stream-count "$STREAM_COUNT" --stream-delay "$STREAM_DELAY" \
  > "$SERVER_LOG" 2>&1 & echo $! > "$SERVER_PID_FILE"

if ! wait_for_port "$PORT"; then
  echo "Server failed to start on $HOST:$PORT (log: $SERVER_LOG)" >&2
  exit 1
fi

printf "==> Running slow reader (delay=%s, max=%s)\n" "$READ_DELAY" "$MAX_MESSAGES"
dune exec --profile="$PROFILE" bench/slow_reader_client.exe -- \
  --target "http://$HOST:$PORT" \
  --delay "$READ_DELAY" \
  --max "$MAX_MESSAGES" \
  > "$CLIENT_LOG" 2>&1

echo "Slow reader completed. Logs: $SERVER_LOG, $CLIENT_LOG"
