#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
CHECKOUT="$ROOT/src"
WRAPPER="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab/scripts/run_libfuzzer_target.sh"
LANE_REGISTRY="$ROOT/fuzz/managed/lane_registry.json"
MAX_TOTAL_TIME="${MAX_TOTAL_TIME:-172800}"
DICT_PATH="$ROOT/fuzz/managed/angle_texture_vk_pitch_narrow_fuzzer.dict"

exec nice -n 15 /bin/bash "$WRAPPER" \
  --binary "$CHECKOUT/out/libfuzzer-trend/angle_texture_vk_pitch_narrow_fuzzer" \
  --component gpu \
  --target angle_texture_vk_pitch_narrow_fuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$ROOT/fuzz/corpus/angle_texture_vk_pitch_narrow" \
  --max-total-time "$MAX_TOTAL_TIME" \
  --lane-registry "$LANE_REGISTRY" \
  -- \
  -dict="$DICT_PATH" \
  -timeout=15 \
  -max_len=128
