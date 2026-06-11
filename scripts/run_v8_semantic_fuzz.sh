#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
CHECKOUT="$ROOT/src"
SKILL_ROOT="${CHROMIUM_FUZZING_LAB_SKILL_ROOT:-/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab}"
if [[ ! -d "$SKILL_ROOT/scripts" ]]; then
  SKILL_ROOT="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab"
fi
WRAPPER="$SKILL_ROOT/scripts/run_libfuzzer_target.sh"
LANE_REGISTRY="$ROOT/fuzz/managed/lane_registry.json"
MAX_TOTAL_TIME="${MAX_TOTAL_TIME:-86400}"
CORPUS_DIR="$ROOT/fuzz/corpus/v8_script_parser"
FRESH_BINARY_MAX_AGE_SECS="${FRESH_BINARY_MAX_AGE_SECS:-604800}"

first_existing_binary() {
  local candidate=""
  for candidate in "$@"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "$1"
}

BINARY="$(
  first_existing_binary \
    "$CHECKOUT/out/libfuzzer-current/v8_script_parser_fuzzer" \
    "$CHECKOUT/out/libfuzzer-narrow-linux/v8_script_parser_fuzzer" \
    "$CHECKOUT/out/libfuzzer-trend/v8_script_parser_fuzzer"
)"

/bin/bash "$ROOT/fuzz/run_v8_semantic_lane.sh" >/dev/null

if [[ ! -x "$WRAPPER" ]]; then
  echo "[run_v8_semantic_fuzz] wrapper missing: $WRAPPER" >&2
  exit 2
fi
if [[ ! -x "$BINARY" ]]; then
  echo "[run_v8_semantic_fuzz] v8_script_parser_fuzzer missing: $BINARY" >&2
  exit 2
fi
binary_mtime="$(stat -f '%m' "$BINARY" 2>/dev/null || stat -c '%Y' "$BINARY" 2>/dev/null || echo 0)"
binary_age=$(( $(date +%s) - binary_mtime ))
if (( binary_age > FRESH_BINARY_MAX_AGE_SECS )); then
  echo "[run_v8_semantic_fuzz] warning: old binary, support-only run age_days=$(( binary_age / 86400 )) binary=$BINARY" >&2
fi

exec nice -n 15 /bin/bash "$WRAPPER" \
  --binary "$BINARY" \
  --component v8 \
  --target v8_script_parser_fuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$CORPUS_DIR" \
  --max-total-time "$MAX_TOTAL_TIME" \
  --lane-registry "$LANE_REGISTRY" \
  -- \
  -timeout=20 \
  -rss_limit_mb=2048 \
  -max_len=4096
