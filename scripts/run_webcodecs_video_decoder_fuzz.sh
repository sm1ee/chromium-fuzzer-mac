#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
CHECKOUT="$ROOT/src"
WRAPPER="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab/scripts/run_libfuzzer_target.sh"
LANE_REGISTRY="$ROOT/fuzz/managed/lane_registry.json"
MAX_TOTAL_TIME="${MAX_TOTAL_TIME:-172800}"
DICT_PATH="$ROOT/fuzz/managed/webcodecs_video_decoder_fuzzer.dict"

exec nice -n 15 /bin/bash "$WRAPPER" \
  --binary "$CHECKOUT/out/libfuzzer-trend/webcodecs_video_decoder_fuzzer" \
  --component webcodecs \
  --target webcodecs_video_decoder_fuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$ROOT/fuzz/corpus/webcodecs_video_decoder" \
  --max-total-time "$MAX_TOTAL_TIME" \
  --lane-registry "$LANE_REGISTRY" \
  -- \
  -dict="$DICT_PATH" \
  -max_len=131072 \
  -keep_seed=1
