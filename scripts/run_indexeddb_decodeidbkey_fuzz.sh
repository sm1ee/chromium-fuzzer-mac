#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
CHECKOUT="$ROOT/src"
WRAPPER="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab/scripts/run_libfuzzer_target.sh"
LANE_REGISTRY="$ROOT/fuzz/managed/lane_registry.json"
MAX_TOTAL_TIME="${MAX_TOTAL_TIME:-172800}"

exec nice -n 15 /bin/bash "$WRAPPER" \
  --binary "$CHECKOUT/out/libfuzzer-trend/indexed_db_leveldb_coding_decodeidbkey_fuzzer" \
  --component indexeddb \
  --target indexed_db_leveldb_coding_decodeidbkey_fuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$ROOT/fuzz/corpus/indexed_db_leveldb_coding_decodeidbkey_fuzzer" \
  --max-total-time "$MAX_TOTAL_TIME" \
  --lane-registry "$LANE_REGISTRY"
