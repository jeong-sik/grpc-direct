#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GO_DIR="$ROOT/bench/go-comparison"
LOG_DIR="${LOG_DIR:-$ROOT/tmp}"
DUNE_PROFILE="${DUNE_PROFILE:-release}"

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-50051}"
STREAM_COUNT="${STREAM_COUNT:-10}"
CANCEL_AFTER="${CANCEL_AFTER:-2}"

SERVER_BIN="$ROOT/_build/default/bench/interop_streaming_server.exe"
GO_BIN="$GO_DIR/tmp_interop_client_smoke"

SERVER_LOG="$LOG_DIR/interop_smoke_server.log"
CLIENT_LOG="$LOG_DIR/interop_smoke_client.log"

server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}
trap cleanup EXIT INT TERM

wait_for_server() {
  local host="$1"
  local port="$2"
  local attempts=100
  local attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "Server exited early. See ${SERVER_LOG}" >&2
      if [[ -f "$SERVER_LOG" ]]; then
        sed -n '1,200p' "$SERVER_LOG" >&2 || true
      fi
      exit 1
    fi

    if (exec 3<>/dev/tcp/"${host}"/"${port}") 2>/dev/null; then
      exec 3<&-
      exec 3>&-
      return 0
    fi
    sleep 0.1
  done
  echo "Server did not start within timeout. See ${SERVER_LOG}" >&2
  exit 1
}

mkdir -p "$LOG_DIR"

(
  cd "$ROOT"
  dune build --root "$ROOT" --profile="$DUNE_PROFILE" bench/interop_streaming_server.exe
)

(
  cd "$GO_DIR"
  go build -tags=interop_client -o "$GO_BIN" .
)

(
  cd "$ROOT"
  exec "$SERVER_BIN" --host "$HOST" --port "$PORT" --stream-count "$STREAM_COUNT"
) > "$SERVER_LOG" 2>&1 &
server_pid=$!

wait_for_server "$HOST" "$PORT"

(
  cd "$GO_DIR"
  "$GO_BIN" --addr "${HOST}:${PORT}" \
    --stream-count "$STREAM_COUNT" \
    --cancel-after "$CANCEL_AFTER"
) > "$CLIENT_LOG" 2>&1

echo "Interop smoke completed."
