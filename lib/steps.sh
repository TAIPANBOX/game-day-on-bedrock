#!/usr/bin/env bash
# Shared step library for the game-day CI sample.
#
# game-day.yml (the GitHub Actions workflow in this repository) and
# run-local.sh (its rehearsal on a developer's own machine) both source this
# file and call the same functions in the same order. run-local.sh is not a
# paraphrase of the workflow's steps: it is the same commands, so a local run
# and a CI run can only differ in where the binaries come from and whether the
# notifier is on, both controlled by env vars below, never by different code.
#
# Required env:
#   BINARY_SOURCE    "release" (fetch the gateway from its GitHub release and
#                    build the two Go tools from source at pinned commits), or a
#                    local directory already holding the three binaries.
#   WORKDIR          scratch directory for this run's state (created if missing).
# Optional env:
#   HERALDYX_ENABLED "true" (default) or "false". The on-purpose failure drill
#                    sets this to "false" and expects the reaction check to go red.

set -euo pipefail

: "${BINARY_SOURCE:?set BINARY_SOURCE to \"release\" or a local directory}"
: "${WORKDIR:?set WORKDIR to a scratch directory}"
: "${HERALDYX_ENABLED:=true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pins. The gateway is a Rust release binary; the two Go tools have no tagged
# release with a Linux binary yet, so they are built from source at a commit.
TOKENFUSE_VERSION="v0.4.3"
TOKENFUSE_RELEASE="https://github.com/TAIPANBOX/tokenfuse/releases/download"
MOCKRYX_COMMIT="d2b495a6c83bf10e746300cdb3c3791e970d2b12"
HERALDYX_COMMIT="31850f372acfdb32c499e2f51fb4f107869f4404"

STUB_PORT=4200
GATEWAY_PORT=4100
GATEWAY_ADDR="127.0.0.1:${GATEWAY_PORT}"

# name:fault_mode for stub.py's FAULT env var, one entry per scenario file
# under scenarios/. Order matches the article's own three faults.
SCENARIOS=(
  "bedrock-throttle.yaml:throttle"
  "bedrock-model-retired.yaml:retired"
  "bedrock-region-failover.yaml:ok"
)

_tokenfuse_asset() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  echo "tokenfuse-aarch64-apple-darwin" ;;
    Darwin-x86_64) echo "tokenfuse-x86_64-apple-darwin" ;;
    Linux-x86_64)  echo "tokenfuse-x86_64-unknown-linux-musl" ;;
    Linux-aarch64) echo "tokenfuse-aarch64-unknown-linux-musl" ;;
    *) echo "no tokenfuse release asset for $(uname -s)-$(uname -m)" >&2; return 1 ;;
  esac
}

fetch_binaries() {
  mkdir -p "$WORKDIR/bin"
  if [[ "$BINARY_SOURCE" == "release" ]]; then
    local asset; asset="$(_tokenfuse_asset)"
    echo "fetch: ${TOKENFUSE_RELEASE}/${TOKENFUSE_VERSION}/${asset} -> $WORKDIR/bin/tokenfuse"
    curl -fsSL "${TOKENFUSE_RELEASE}/${TOKENFUSE_VERSION}/${asset}" -o "$WORKDIR/bin/tokenfuse"
    echo "build: github.com/TAIPANBOX/mockryx/cmd/mockryx@${MOCKRYX_COMMIT}"
    GOBIN="$WORKDIR/bin" GOFLAGS=-mod=mod go install "github.com/TAIPANBOX/mockryx/cmd/mockryx@${MOCKRYX_COMMIT}"
    mv "$WORKDIR/bin/mockryx" "$WORKDIR/bin/bin-mockryx"
    echo "build: github.com/TAIPANBOX/heraldyx/cmd/heraldyx@${HERALDYX_COMMIT}"
    GOBIN="$WORKDIR/bin" GOFLAGS=-mod=mod go install "github.com/TAIPANBOX/heraldyx/cmd/heraldyx@${HERALDYX_COMMIT}"
    mv "$WORKDIR/bin/heraldyx" "$WORKDIR/bin/bin-heraldyx"
  else
    local asset; asset="$(_tokenfuse_asset)"
    echo "copy (local dir, no network): $BINARY_SOURCE/{$asset,bin-heraldyx,bin-mockryx} -> $WORKDIR/bin/"
    cp "$BINARY_SOURCE/$asset" "$WORKDIR/bin/tokenfuse"
    cp "$BINARY_SOURCE/bin-heraldyx" "$WORKDIR/bin/bin-heraldyx"
    cp "$BINARY_SOURCE/bin-mockryx" "$WORKDIR/bin/bin-mockryx"
  fi
  chmod +x "$WORKDIR"/bin/*
  "$WORKDIR/bin/bin-mockryx" version || true
  "$WORKDIR/bin/bin-heraldyx" -version || true
}

_wait_for() {
  # _wait_for <description> <check-command...>
  local desc="$1"; shift
  local i
  for i in $(seq 1 50); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "timed out waiting for: $desc" >&2
  return 1
}

start_stub() {
  local fault="$1"
  pkill -f "local/stub.py" 2>/dev/null || true
  sleep 0.2
  FAULT="$fault" python3 "$REPO_ROOT/local/stub.py" > "$WORKDIR/stub.log" 2>&1 &
  echo $! > "$WORKDIR/stub.pid"
  _wait_for "stub on :${STUB_PORT}" curl -s -X POST "http://127.0.0.1:${STUB_PORT}/v1/messages" -d '{}'
}

start_tokenfuse() {
  mkdir -p "$WORKDIR/events"
  : > "$WORKDIR/events/tokenfuse.ndjson"
  TOKENFUSE_UPSTREAM="http://127.0.0.1:${STUB_PORT}/v1/messages" \
  TOKENFUSE_MODE=enforce \
  TOKENFUSE_EVENTS_PATH="$WORKDIR/events/tokenfuse.ndjson" \
  "$WORKDIR/bin/tokenfuse" > "$WORKDIR/tokenfuse.log" 2>&1 &
  echo $! > "$WORKDIR/tokenfuse.pid"
  _wait_for "tokenfuse gateway on :${GATEWAY_PORT}" grep -q "listening" "$WORKDIR/tokenfuse.log"
}

start_heraldyx() {
  mkdir -p "$WORKDIR/heraldyx-state"
  : > "$WORKDIR/heraldyx-state/sent.ndjson"
  if [[ "$HERALDYX_ENABLED" != "true" ]]; then
    echo "heraldyx disabled for this run (HERALDYX_ENABLED=$HERALDYX_ENABLED); sent.ndjson stays empty"
    rm -f "$WORKDIR/heraldyx.pid"
    return 0
  fi
  HERALDYX_EVENTS="$WORKDIR/events" \
  HERALDYX_TO="oncall@example.com" \
  HERALDYX_MAIL_FILE="$WORKDIR/mail.txt" \
  HERALDYX_STATE="$WORKDIR/heraldyx-state/state.json" \
  HERALDYX_SENT="$WORKDIR/heraldyx-state/sent.ndjson" \
  HERALDYX_MIN_SEVERITY=medium \
  HERALDYX_POLL_MS=500 \
  "$WORKDIR/bin/bin-heraldyx" --from-now=false > "$WORKDIR/heraldyx.log" 2>&1 &
  echo $! > "$WORKDIR/heraldyx.pid"
  sleep 0.5
}

run_scenarios() {
  local overall=0
  mkdir -p "$WORKDIR/scen"
  for entry in "${SCENARIOS[@]}"; do
    local file="${entry%%:*}"
    local fault="${entry##*:}"
    echo "=== scenario: $file (stub FAULT=$fault) ==="
    start_stub "$fault"

    local scen_dir="$WORKDIR/scen/${file%.yaml}"
    mkdir -p "$scen_dir"
    cp "$REPO_ROOT/scenarios/$file" "$scen_dir/"

    local rc=0
    "$WORKDIR/bin/bin-mockryx" run \
      --gateway "http://${GATEWAY_ADDR}" \
      --watch-events "$WORKDIR/events/tokenfuse.ndjson" \
      --watch-events "$WORKDIR/heraldyx-state/sent.ndjson" \
      "$scen_dir" || rc=$?

    echo "scenario $file exited $rc"
    if [[ "$rc" -ne 0 ]]; then
      overall=1
    fi
  done
  echo "run_scenarios: overall exit code $overall"
  return $overall
}

teardown() {
  for pidfile in "$WORKDIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    local pid
    pid=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  pkill -f "local/stub.py" 2>/dev/null || true
  sleep 0.3
}
