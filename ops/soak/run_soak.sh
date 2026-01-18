#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${LOG_DIR:-$ROOT/tmp}"
DURATION_SECONDS="${DURATION_SECONDS:-86400}"
CONCURRENCY="${CONCURRENCY:-50}"
DURATION_PER_RUN="${DURATION_PER_RUN:-30s}"

mkdir -p "$LOG_DIR"

SERVER_LOG="$LOG_DIR/soak_server.log"
CLIENT_LOG="$LOG_DIR/soak_client.log"
SERVER_PID_FILE="$LOG_DIR/soak_server.pid"

cleanup() {
  if [[ -f "$SERVER_PID_FILE" ]]; then
    kill "$(cat "$SERVER_PID_FILE")" 2>/dev/null || true
    rm -f "$SERVER_PID_FILE"
  fi
}
trap cleanup EXIT

cd "$ROOT"

nohup dune exec --profile=release bench/bench_server.exe > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > "$SERVER_PID_FILE"

sleep 1

START=$(date +%s)
END=$((START + DURATION_SECONDS))

while [[ $(date +%s) -lt $END ]]; do
  ghz --insecure --proto bench/go-comparison/echo.proto \
    --call echo.EchoService/Echo -d '{"message":"hello"}' \
    -c "$CONCURRENCY" -z "$DURATION_PER_RUN" 127.0.0.1:50099 >> "$CLIENT_LOG"
  sleep 1
  printf "[soak] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$CLIENT_LOG"
done
