#!/usr/bin/env bash
# Local rehearsal of game-day.yml's own steps, on this Mac, in a fresh shell.
#
# This script does not reimplement the workflow: it sources the same
# lib/steps.sh the workflow sources and calls the same functions in the
# same order (fetch_binaries, start_tokenfuse, start_heraldyx,
# run_scenarios, teardown). The only two things that differ from a
# GitHub-hosted run are supplied as env vars, not as different code:
#
#   BINARY_SOURCE     here, a local directory already holding the three
#                     binaries (no network call), instead of "release".
#   HERALDYX_ENABLED  "true" by default (RUNBOOK.md step 4); pass
#                     HERALDYX_ENABLED=false to run RUNBOOK.md step 5's
#                     on-purpose failure.
#
# Usage:
#   ./run-local.sh                        # step 4: normal run
#   HERALDYX_ENABLED=false ./run-local.sh  # step 5: the drill that must fail
#
# BINARY_SOURCE is a directory holding the gateway release binary for this
# platform, bin-heraldyx and bin-mockryx, or the word "release" to fetch and
# build exactly as the workflow does.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${BINARY_SOURCE:?set BINARY_SOURCE to a directory holding the three binaries, or \"release\"}"
: "${HERALDYX_ENABLED:=true}"
export BINARY_SOURCE HERALDYX_ENABLED
export WORKDIR="${WORKDIR:-$(mktemp -d /tmp/d5-game-day-local.XXXXXX)}"

echo "run-local.sh: BINARY_SOURCE=$BINARY_SOURCE"
echo "run-local.sh: HERALDYX_ENABLED=$HERALDYX_ENABLED"
echo "run-local.sh: WORKDIR=$WORKDIR"

# shellcheck source=lib/steps.sh
source "$SCRIPT_DIR/lib/steps.sh"

cleanup() {
  teardown
}
trap cleanup EXIT

fetch_binaries
start_tokenfuse
start_heraldyx

set +e
run_scenarios
rc=$?
set -e

echo
echo "run-local.sh: overall exit code $rc"
exit $rc
