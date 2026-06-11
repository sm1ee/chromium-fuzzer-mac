#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
CHECKOUT="$ROOT/src"
WRAPPER="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab/scripts/run_fuzztest_target.sh"
MAX_TOTAL_TIME="${MAX_TOTAL_TIME:-3600}"
LANE_REGISTRY="$ROOT/fuzz/managed/lane_registry.json"

/bin/bash "$ROOT/fuzz/run_dawn_wire_lifecycle_lane.sh" >/dev/null

exec nice -n 15 /bin/bash "$WRAPPER" \
  --binary "$CHECKOUT/out/libfuzzer-trend/dawn_wire_lifecycle_sequence_fuzztest_DawnWireLifecycleSequenceFuzzTest_HandlesWireLifecycleSequence_fuzzer" \
  --component gpu \
  --target dawn_wire_lifecycle_sequence \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --lane-registry "$LANE_REGISTRY" \
  -- \
  -max_total_time="$MAX_TOTAL_TIME" \
  -rss_limit_mb=1024
