#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${LOG_DIR:-$ROOT/tmp}"
PROFILE="${PROFILE:-release}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-50090}"
H2SPEC="${H2SPEC:-h2spec}"
STRICT="${STRICT:-1}"
H2SPEC_ARGS="${H2SPEC_ARGS:-}"

SERVER_LOG="$LOG_DIR/h2spec_server.log"
SERVER_PID_FILE="$LOG_DIR/h2spec_server.pid"

mkdir -p "$LOG_DIR"

cleanup() {
  if [[ -f "$SERVER_PID_FILE" ]]; then
    kill "$(cat "$SERVER_PID_FILE")" 2>/dev/null || true
    rm -f "$SERVER_PID_FILE"
  fi
}
trap cleanup EXIT

if ! command -v "$H2SPEC" >/dev/null 2>&1; then
  echo "h2spec not found. Install via: go install github.com/summerwind/h2spec/cmd/h2spec@latest" >&2
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

echo "==> Building h2spec_server (profile=$PROFILE)"
dune build --profile="$PROFILE" bench/h2spec_server.exe

echo "==> Starting h2spec_server on $HOST:$PORT"
nohup dune exec --profile="$PROFILE" bench/h2spec_server.exe -- \
  --port "$PORT" > "$SERVER_LOG" 2>&1 & echo $! > "$SERVER_PID_FILE"

if ! wait_for_port "$PORT"; then
  echo "Server failed to start on $HOST:$PORT (log: $SERVER_LOG)" >&2
  exit 1
fi

args=(-h "$HOST" -p "$PORT")
if [ "$STRICT" -eq 1 ]; then
  if "$H2SPEC" --help 2>&1 | grep -q -- "--strict"; then
    args+=(--strict)
  elif "$H2SPEC" --help 2>&1 | grep -q -- "-S"; then
    args+=(-S)
  else
    echo "Strict mode flag not supported by h2spec; skipping." >&2
  fi
fi

ts="$(date +%Y%m%d_%H%M%S)"
log_file="$LOG_DIR/h2spec_${ts}.log"

echo "==> Running h2spec (log: $log_file)"
"$H2SPEC" "${args[@]}" ${H2SPEC_ARGS} | tee "$log_file"

echo "h2spec completed."
