#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PODMAN_BIN="${PODMAN_BIN:-podman}"
NETWORK="idle-timeout-testnet"
SERVER_CONTAINER="idle-timeout-server"
MIDDLEBOX_CONTAINER="idle-timeout-middlebox"
NODE_IMAGE="localhost/idle-timeout-node:latest"
MIDDLEBOX_IMAGE="localhost/idle-timeout-middlebox:latest"

usage() {
  echo "Usage: scripts/testbed.sh <command> [arguments]"
  echo
  echo "Commands:"
  echo "  doctor                         Check required tooling"
  echo "  build                          Build both Podman images"
  echo "  up [timeout] [heartbeat]       Start server and middlebox (defaults: 15 10)"
  echo "  down                           Stop testbed containers"
  echo "  status                         Show container status"
  echo "  run <websocket|sse> [timeout] [heartbeat] [idle] [rep]"
  echo "  matrix [repetitions]           Run the thesis matrix (default: 10)"
  echo "  export                         Write hasil_mentah.csv and hasil_ringkas.csv"
  echo "  archive                        Archive current data and start clean"
}

require_podman() {
  command -v "$PODMAN_BIN" >/dev/null 2>&1 || {
    echo "Podman is not installed. Install Podman, then run: podman machine init && podman machine start" >&2
    exit 1
  }
  "$PODMAN_BIN" info >/dev/null 2>&1 || {
    echo "Podman is installed but its engine is unavailable." >&2
    echo "On macOS/Windows run: podman machine init (once), then podman machine start" >&2
    exit 1
  }
}

remove_container() {
  "$PODMAN_BIN" rm -f "$1" >/dev/null 2>&1 || true
}

build_images() {
  require_podman
  "$PODMAN_BIN" build -t "$NODE_IMAGE" -f "$ROOT_DIR/Containerfile" "$ROOT_DIR"
  "$PODMAN_BIN" build -t "$MIDDLEBOX_IMAGE" -f "$ROOT_DIR/nginx/Containerfile" "$ROOT_DIR/nginx"
}

ensure_images() {
  "$PODMAN_BIN" image exists "$NODE_IMAGE" && "$PODMAN_BIN" image exists "$MIDDLEBOX_IMAGE" || build_images
}

start_testbed() {
  local timeout_seconds="${1:-15}"
  local heartbeat_seconds="${2:-10}"
  require_podman
  ensure_images
  mkdir -p "$ROOT_DIR/logs" "$ROOT_DIR/captures"
  "$PODMAN_BIN" network inspect "$NETWORK" >/dev/null 2>&1 || "$PODMAN_BIN" network create "$NETWORK" >/dev/null
  remove_container "$MIDDLEBOX_CONTAINER"
  remove_container "$SERVER_CONTAINER"

  "$PODMAN_BIN" run -d --name "$SERVER_CONTAINER" --network "$NETWORK" --network-alias server \
    -e "HEARTBEAT_INTERVAL=$heartbeat_seconds" -e LOG_DIR=/app/logs \
    -v "$ROOT_DIR/logs:/app/logs:Z" "$NODE_IMAGE" >/dev/null

  "$PODMAN_BIN" run -d --name "$MIDDLEBOX_CONTAINER" --network "$NETWORK" --network-alias middlebox \
    --cap-add=NET_RAW -e "IDLE_TIMEOUT=$timeout_seconds" -p 8080:8080 \
    -v "$ROOT_DIR/captures:/captures:Z" "$MIDDLEBOX_IMAGE" >/dev/null

  local attempt
  for attempt in $(seq 1 30); do
    if "$PODMAN_BIN" exec "$MIDDLEBOX_CONTAINER" wget -q -O - http://127.0.0.1:8080/health >/dev/null 2>&1; then
      echo "Testbed ready: timeout=${timeout_seconds}s heartbeat=${heartbeat_seconds}s URL=http://127.0.0.1:8080"
      return
    fi
    sleep 1
  done
  echo "Testbed failed its health check. Inspect: $PODMAN_BIN logs $SERVER_CONTAINER" >&2
  exit 1
}

stop_testbed() {
  require_podman
  remove_container "$MIDDLEBOX_CONTAINER"
  remove_container "$SERVER_CONTAINER"
  echo "Testbed containers stopped (logs and captures retained)."
}

run_scenario() {
  local impl="${1:-websocket}"
  local timeout_seconds="${2:-15}"
  local heartbeat_seconds="${3:-10}"
  local idle_seconds="${4:-$((timeout_seconds + 15))}"
  local repetition="${5:-1}"
  if [[ "$impl" != "websocket" && "$impl" != "sse" ]]; then
    echo "Implementation must be websocket or sse" >&2
    exit 2
  fi
  local run_id="${impl}_${timeout_seconds}s_hb${heartbeat_seconds}s_rep$(printf '%02d' "$repetition")"
  if [[ -e "$ROOT_DIR/captures/${run_id}.pcap" ]] || \
     { [[ -f "$ROOT_DIR/logs/client.log" ]] && grep -Fq "\"run_id\":\"${run_id}\"" "$ROOT_DIR/logs/client.log"; }; then
    echo "Run ID already exists: $run_id" >&2
    echo "Use another repetition or run './scripts/testbed.sh archive' before a new dataset." >&2
    exit 2
  fi
  start_testbed "$timeout_seconds" "$heartbeat_seconds"
  "$PODMAN_BIN" exec -d "$MIDDLEBOX_CONTAINER" tcpdump -i any -U -w "/captures/${run_id}.pcap" \
    "tcp port 8080 or tcp port 3000"
  local exit_code=0
  "$PODMAN_BIN" run --rm --network "$NETWORK" \
    -e LOG_DIR=/app/logs -v "$ROOT_DIR/logs:/app/logs:Z" "$NODE_IMAGE" \
    node client/run_test.js --base-url=http://middlebox:8080 --impl="$impl" \
    --timeout="$timeout_seconds" --heartbeat="$heartbeat_seconds" --idle="$idle_seconds" \
    --rep="$repetition" --run-id="$run_id" || exit_code=$?
  "$PODMAN_BIN" exec "$MIDDLEBOX_CONTAINER" pkill -INT tcpdump >/dev/null 2>&1 || true
  sleep 1
  if [[ ! -s "$ROOT_DIR/captures/${run_id}.pcap" ]]; then
    echo "Packet capture missing or empty: captures/${run_id}.pcap" >&2
    exit_code=1
  fi
  stop_testbed
  return "$exit_code"
}

run_matrix() {
  local repetitions="${1:-10}"
  local timeout_seconds heartbeat_seconds repetition impl
  for timeout_seconds in 15 30 60 120; do
    local heartbeats=(10)
    [[ "$timeout_seconds" == "15" ]] && heartbeats=(10 15 20)
    for heartbeat_seconds in "${heartbeats[@]}"; do
      for repetition in $(seq 1 "$repetitions"); do
        for impl in websocket sse; do
          run_scenario "$impl" "$timeout_seconds" "$heartbeat_seconds" "$((timeout_seconds + 15))" "$repetition"
        done
      done
    done
  done
  "$ROOT_DIR/scripts/testbed.sh" export
}

archive_data() {
  local timestamp archive_dir path
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive_dir="$ROOT_DIR/artifacts/archive-$timestamp"
  mkdir -p "$archive_dir"
  for path in "$ROOT_DIR/logs" "$ROOT_DIR/captures" "$ROOT_DIR/hasil_mentah.csv" "$ROOT_DIR/hasil_ringkas.csv"; do
    if [[ -e "$path" ]]; then
      mv "$path" "$archive_dir/"
    fi
  done
  mkdir -p "$ROOT_DIR/logs" "$ROOT_DIR/captures"
  echo "Archived current experiment data to $archive_dir"
}

command_name="${1:-}"
case "$command_name" in
  doctor)
    echo "Node local: $(command -v node >/dev/null 2>&1 && node --version || echo 'not found (Podman will be used)')"
    echo "Nginx local: $(command -v nginx >/dev/null 2>&1 && nginx -v 2>&1 || echo 'not found (Podman will be used)')"
    require_podman
    echo "Podman: $($PODMAN_BIN --version)"
    echo "Podman engine: ready"
    ;;
  build) build_images ;;
  up) start_testbed "${2:-15}" "${3:-10}" ;;
  down) stop_testbed ;;
  status) require_podman; "$PODMAN_BIN" ps -a --filter "name=idle-timeout-" ;;
  run) run_scenario "${2:-websocket}" "${3:-15}" "${4:-10}" "${5:-}" "${6:-1}" ;;
  matrix) run_matrix "${2:-10}" ;;
  export) python3 "$ROOT_DIR/scripts/export-results.py" ;;
  archive) archive_data ;;
  *) usage; [[ -n "$command_name" ]] && exit 2 || exit 0 ;;
esac
