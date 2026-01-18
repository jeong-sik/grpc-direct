#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_DIR="$ROOT/bench"
GO_DIR="$BENCH_DIR/go-comparison"
RUST_DIR="$BENCH_DIR/rust-comparison"

HOST="127.0.0.1"
PORT="50051"
STREAM_COUNT=100
CANCEL_AFTER=5
SHUTDOWN_AFTER=5
REPEAT=1
PORT_OFFSET=0
RUN_PLAINTEXT=1
RUN_TLS=1
RUN_IDENTITY=1
RUN_GZIP=1
RUN_GOAWAY=1
DUNE_PROFILE="release"

SERVER_BIN="$ROOT/_build/default/bench/interop_streaming_server.exe"
GO_BIN="$GO_DIR/tmp_interop_client"
RUST_BIN="$RUST_DIR/target/release/interop_streaming_client"

TLS_DIR="$ROOT/tmp_tls"
SERVER_CERT="$TLS_DIR/server.pem"
SERVER_KEY="$TLS_DIR/server.key"
CLIENT_CA="$TLS_DIR/ca.pem"
SERVER_NAME="localhost"

server_pid=""

usage() {
  cat <<'USAGE'
Usage: run_interop_suite.sh [options]

Options:
  --host <ip>             Server bind host (default: 127.0.0.1)
  --port <port>           Server port (default: 50051)
  --stream-count <n>      Server stream count (default: 100)
  --cancel-after <n>      Cancel after N responses (default: 5)
  --repeat <n>            Repeat the full matrix N times (default: 1)
  --plaintext-only        Run only plaintext cases
  --tls-only              Run only TLS cases
  --no-gzip               Disable gzip cases
  --gzip-only             Run only gzip cases
  --skip-goaway           Skip GOAWAY/close tests
  --server-cert <path>    TLS server cert (default: tmp_tls/server.pem)
  --server-key <path>     TLS server key (default: tmp_tls/server.key)
  --client-ca <path>      Client CA cert (default: tmp_tls/ca.pem)
  --server-name <name>    TLS server name (default: localhost)
  --dune-profile <name>   Dune profile (default: release)
  --help                  Show this help
USAGE
}

cleanup() {
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
    server_pid=""
  fi
}

wait_for_server() {
  local log="$1"
  local host="$2"
  local port="$3"
  local attempts=200
  local attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    if ! kill -0 "${server_pid}" 2>/dev/null; then
      echo "Server exited early. See ${log}" >&2
      if [[ -f "${log}" ]]; then
        sed -n '1,200p' "${log}" >&2 || true
      fi
      exit 1
    fi

    if [[ -f "${log}" ]] && grep -q "Interop streaming server" "${log}" 2>/dev/null; then
      return 0
    fi

    if (exec 3<>/dev/tcp/"${host}"/"${port}") 2>/dev/null; then
      exec 3<&-
      exec 3>&-
      return 0
    fi
    sleep 0.1
  done
  echo "Server did not start within timeout. See ${log}" >&2
  exit 1
}

trap cleanup EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="$2"; shift 2 ;;
    --port)
      PORT="$2"; shift 2 ;;
    --stream-count)
      STREAM_COUNT="$2"; shift 2 ;;
    --cancel-after)
      CANCEL_AFTER="$2"; shift 2 ;;
    --repeat)
      REPEAT="$2"; shift 2 ;;
    --plaintext-only)
      RUN_TLS=0; shift ;;
    --tls-only)
      RUN_PLAINTEXT=0; shift ;;
    --no-gzip)
      RUN_GZIP=0; shift ;;
    --gzip-only)
      RUN_IDENTITY=0; shift ;;
    --skip-goaway)
      RUN_GOAWAY=0; shift ;;
    --server-cert)
      SERVER_CERT="$2"; shift 2 ;;
    --server-key)
      SERVER_KEY="$2"; shift 2 ;;
    --client-ca)
      CLIENT_CA="$2"; shift 2 ;;
    --server-name)
      SERVER_NAME="$2"; shift 2 ;;
    --dune-profile)
      DUNE_PROFILE="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
 done

build_artifacts() {
  (cd "$ROOT"; dune build --profile="$DUNE_PROFILE" bench/interop_streaming_server.exe)
  (cd "$GO_DIR"; go build -tags=interop_client -o "$GO_BIN" .)
  (cd "$RUST_DIR"; cargo build --release --bin interop_streaming_client)
}

if [[ "$RUN_TLS" -eq 1 ]]; then
  if [[ ! -f "$SERVER_CERT" || ! -f "$SERVER_KEY" ]]; then
    echo "Missing TLS cert/key. Set --server-cert/--server-key." >&2
    exit 1
  fi
  if [[ ! -f "$CLIENT_CA" ]]; then
    echo "Missing client CA. Set --client-ca." >&2
    exit 1
  fi
fi

build_artifacts

start_server() {
  local tls="$1"
  local gzip="$2"
  local shutdown_after="$3"
  local log="$4"
  local port="$5"
  local args=(--host "$HOST" --port "$port" --stream-count "$STREAM_COUNT")

  if [[ "$gzip" -eq 1 ]]; then
    args+=(--gzip)
  fi

  if [[ "$shutdown_after" -gt 0 ]]; then
    args+=(--shutdown-after "$shutdown_after")
  fi

  if [[ "$tls" -eq 1 ]]; then
    args+=(--cert "$SERVER_CERT" --key "$SERVER_KEY")
  fi

  (
    cd "$ROOT"
    exec "$SERVER_BIN" "${args[@]}"
  ) > "$log" 2>&1 &
  server_pid=$!
  wait_for_server "$log" "$HOST" "$port"
}

stop_server() {
  cleanup
  sleep 0.2
}

run_go() {
  local tls="$1"
  local gzip="$2"
  local wait_goaway="$3"
  local log="$4"
  local port="$5"
  local args=(--addr "${HOST}:${port}" --stream-count "$STREAM_COUNT" --cancel-after "$CANCEL_AFTER")

  if [[ "$tls" -eq 1 ]]; then
    args+=(--tls --ca "$CLIENT_CA" --server-name "$SERVER_NAME")
  fi

  if [[ "$gzip" -eq 1 ]]; then
    args+=(--gzip)
  fi

  if [[ "$wait_goaway" -eq 1 ]]; then
    args+=(--wait-goaway)
  fi

  (
    cd "$GO_DIR"
    "$GO_BIN" "${args[@]}"
  ) > "$log" 2>&1
}

run_rust() {
  local tls="$1"
  local gzip="$2"
  local wait_goaway="$3"
  local log="$4"
  local port="$5"
  local target

  if [[ "$tls" -eq 1 ]]; then
    target="https://${SERVER_NAME}:${port}"
  else
    target="http://${HOST}:${port}"
  fi

  local args=(--target "$target" --stream-count "$STREAM_COUNT" --cancel-after "$CANCEL_AFTER")

  if [[ "$tls" -eq 1 ]]; then
    args+=(--ca "$CLIENT_CA")
  fi

  if [[ "$gzip" -eq 1 ]]; then
    args+=(--gzip)
  fi

  if [[ "$wait_goaway" -eq 1 ]]; then
    args+=(--wait-goaway)
  fi

  (
    cd "$RUST_DIR"
    "$RUST_BIN" "${args[@]}"
  ) > "$log" 2>&1
}

run_suite() {
  local tls="$1"
  local gzip="$2"
  local iter="$3"
  local mode
  local comp

  if [[ "$tls" -eq 1 ]]; then mode="tls"; else mode="plain"; fi
  if [[ "$gzip" -eq 1 ]]; then comp="gzip"; else comp="identity"; fi

  local stamp
  stamp="$(date +"%Y%m%d_%H%M%S")"
  local case_id="${mode}_${comp}_r${iter}_${stamp}"

  local server_log="$BENCH_DIR/tmp_interop_server_${case_id}.log"
  local go_log="$BENCH_DIR/tmp_interop_go_${case_id}.log"
  local rust_log="$BENCH_DIR/tmp_interop_rust_${case_id}.log"
  local port_main=$((PORT + PORT_OFFSET))
  local port_goaway=$((port_main + 1))
  PORT_OFFSET=$((PORT_OFFSET + 2))

  start_server "$tls" "$gzip" 0 "$server_log" "$port_main"
  run_go "$tls" "$gzip" 0 "$go_log" "$port_main"
  run_rust "$tls" "$gzip" 0 "$rust_log" "$port_main"
  stop_server

  if [[ "$RUN_GOAWAY" -eq 1 ]]; then
    local goaway_server_log="$BENCH_DIR/tmp_interop_server_${case_id}_goaway.log"
    local goaway_go_log="$BENCH_DIR/tmp_interop_go_${case_id}_goaway.log"
    local goaway_rust_log="$BENCH_DIR/tmp_interop_rust_${case_id}_goaway.log"

    start_server "$tls" "$gzip" "$SHUTDOWN_AFTER" "$goaway_server_log" "$port_goaway"
    run_go "$tls" "$gzip" 1 "$goaway_go_log" "$port_goaway"
    run_rust "$tls" "$gzip" 1 "$goaway_rust_log" "$port_goaway"
    stop_server
  fi
}

for ((i = 1; i <= REPEAT; i++)); do
  if [[ "$RUN_PLAINTEXT" -eq 1 ]]; then
    if [[ "$RUN_IDENTITY" -eq 1 ]]; then
      run_suite 0 0 "$i"
    fi
    if [[ "$RUN_GZIP" -eq 1 ]]; then
      run_suite 0 1 "$i"
    fi
  fi

  if [[ "$RUN_TLS" -eq 1 ]]; then
    if [[ "$RUN_IDENTITY" -eq 1 ]]; then
      run_suite 1 0 "$i"
    fi
    if [[ "$RUN_GZIP" -eq 1 ]]; then
      run_suite 1 1 "$i"
    fi
  fi
 done

echo "Interop suite completed. Logs in $BENCH_DIR"
