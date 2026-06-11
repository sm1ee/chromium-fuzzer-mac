#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
CHECKOUT="$ROOT/src"
WRAPPER="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab/scripts/run_libfuzzer_target.sh"
LANE_REGISTRY="$ROOT/fuzz/managed/lane_registry.json"
MAX_TOTAL_TIME="${MAX_TOTAL_TIME:-86400}"
DICT_PATH="$ROOT/fuzz/managed/angle_pixelbytes_width_fuzzer.dict"

/bin/bash "$ROOT/fuzz/run_angle_pixelbytes_lane.sh" >/dev/null

exec nice -n 15 /bin/bash "$WRAPPER" \
  --binary "$CHECKOUT/out/libfuzzer-trend/angle_pixelbytes_width_fuzzer" \
  --component gpu \
  --target angle_pixelbytes_width_fuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$ROOT/fuzz/corpus/angle_pixelbytes_width" \
  --max-total-time "$MAX_TOTAL_TIME" \
  --lane-registry "$LANE_REGISTRY" \
  -- \
  -dict="$DICT_PATH" \
  -timeout=15 \
  -rss_limit_mb=1024 \
  -max_len=128
