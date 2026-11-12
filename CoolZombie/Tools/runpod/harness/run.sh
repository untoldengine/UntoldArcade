#!/usr/bin/env bash
# One harness run: run.sh CLIPSET SCENARIO PROFILE [ENV=VAL ...]; prints the CS lines (summary last).
set -euo pipefail
W="$(dirname "$0")/../untold-tune"
CLIPSET=$1 SCENARIO=$2 PROFILE=$3; shift 3
cd "$W" && env -u TOOLCHAINS CLIPSET="$CLIPSET" SCENARIO="$SCENARIO" PROFILE="$PROFILE" "$@" \
  xcrun --toolchain XcodeDefault swift test --filter ZombieClipSetScratchTest 2>&1 | grep -a "^CS \|error:\|failed\|Fatal" || true
