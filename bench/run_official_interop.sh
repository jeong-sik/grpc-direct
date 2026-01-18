#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${PROFILE:-release}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-50051}"
USE_TLS="${USE_TLS:-0}"
CERT_FILE="${CERT_FILE:-$ROOT/tmp_tls/server.pem}"
KEY_FILE="${KEY_FILE:-$ROOT/tmp_tls/server.key}"
CA_FILE="${CA_FILE:-$ROOT/tmp_tls/ca.pem}"
SERVER_NAME="${SERVER_NAME:-localhost}"
USE_TEST_CA="${USE_TEST_CA:-1}"
LOG_DIR="${LOG_DIR:-$ROOT/bench}"
GRPC_GO_VERSION="${GRPC_GO_VERSION:-latest}"

SERVER_LOG="$LOG_DIR/tmp_official_interop_server.log"
SERVER_PID_FILE="$LOG_DIR/tmp_official_interop_server.pid"

SUPPORTED_CASES=(
  empty_unary
  large_unary
  client_streaming
  server_streaming
  ping_pong
  empty_stream
  timeout_on_sleeping_server
  cancel_after_begin
  cancel_after_first_response
  unimplemented_method
  unimplemented_service
)

SKIP_CASES=(
  custom_metadata
  status_code_and_message
  special_status_message
  orca_per_rpc
  orca_oob
  pick_first_unary
  compute_engine_creds
  service_account_creds
  jwt_token_creds
  per_rpc_creds
  oauth2_auth_token
  google_default_credentials
  compute_engine_channel_credentials
)

wait_for_port() {
  local port="$1"
  local retries=50
  local i=0
  while ! nc -z "$HOST" "$port" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge "$retries" ]; then
      return 1
    fi
    sleep 0.1
  done
}

run_case() {
  local case_name="$1"
  local log_file="$LOG_DIR/tmp_official_interop_${case_name}.log"
  if [ "$USE_TLS" -eq 1 ]; then
    local tls_flags=(--use_tls --ca_file "$CA_FILE" --server_host_override "$SERVER_NAME")
    if [ "$USE_TEST_CA" -eq 1 ]; then
      tls_flags+=(--use_test_ca)
    fi
    go run google.golang.org/grpc/interop/client@"$GRPC_GO_VERSION" \
      --server_host "$HOST" \
      --server_port "$PORT" \
      --test_case "$case_name" \
      "${tls_flags[@]}" \
      >"$log_file" 2>&1
  else
    go run google.golang.org/grpc/interop/client@"$GRPC_GO_VERSION" \
      --server_host "$HOST" \
      --server_port "$PORT" \
      --test_case "$case_name" \
      >"$log_file" 2>&1
  fi
}

echo "==> Building interop_official_server (profile=$PROFILE)"
(cd "$ROOT" && dune build --profile="$PROFILE" bench/interop_official_server.exe)

echo "==> Starting interop_official_server on $HOST:$PORT"
if [ "$USE_TLS" -eq 1 ]; then
  (cd "$ROOT" && dune exec --profile="$PROFILE" bench/interop_official_server.exe -- \
    --host "$HOST" --port "$PORT" --cert "$CERT_FILE" --key "$KEY_FILE" \
    >"$SERVER_LOG" 2>&1 & echo $! > "$SERVER_PID_FILE")
else
  (cd "$ROOT" && dune exec --profile="$PROFILE" bench/interop_official_server.exe -- \
    --host "$HOST" --port "$PORT" \
    >"$SERVER_LOG" 2>&1 & echo $! > "$SERVER_PID_FILE")
fi

if [ ! -f "$SERVER_PID_FILE" ]; then
  echo "Server failed to start (no pid file). Log: $SERVER_LOG" >&2
  exit 1
fi

SERVER_PID="$(cat "$SERVER_PID_FILE")"
if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
  echo "Server failed to start (pid not running). Log: $SERVER_LOG" >&2
  exit 1
fi

if ! wait_for_port "$PORT"; then
  echo "Server failed to start on $HOST:$PORT (log: $SERVER_LOG)" >&2
  exit 1
fi

echo "==> Running supported interop cases"
failed=0
for tc in "${SUPPORTED_CASES[@]}"; do
  if run_case "$tc"; then
    echo "PASS: $tc"
  else
    echo "FAIL: $tc (log: $LOG_DIR/tmp_official_interop_${tc}.log)"
    failed=1
  fi
done

echo "==> Skipped cases (unsupported): ${SKIP_CASES[*]}"

echo "==> Stopping server"
if [ -f "$SERVER_PID_FILE" ]; then
  kill "$(cat "$SERVER_PID_FILE")" || true
fi

if [ "$failed" -ne 0 ]; then
  echo "Interop run completed with failures."
  exit 1
fi

echo "Interop run completed."
