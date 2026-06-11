#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"

CHECKOUT_ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp/src"
WORK_ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
DEPOT_TOOLS="/Users/bugclaw/.openclaw/workspace/depot_tools"
CHROMIUM_PYTHON="$DEPOT_TOOLS/bootstrap-2@3.11.8.chromium.35_bin/python3/bin"
OUT_DIR="$CHECKOUT_ROOT/out/libfuzzer-trend"
AUTONINJA_BIN="${AUTONINJA_BIN:-$DEPOT_TOOLS/autoninja}"
NINJA_BIN="$CHECKOUT_ROOT/third_party/ninja/ninja"
NINJA_JOBS="${NINJA_JOBS:-4}"
TARGET="indexed_db_leveldb_coding_sequence_fuzztest_IndexedDbLevelDbCodingSequenceFuzzTest_IndexedDbCodingStatefulSequence_fuzzer"
PLAN_ROOT="$WORK_ROOT/fuzz/managed/plans/indexeddb_stateful_sequence/current"
PROGRESS_NOTE="$PLAN_ROOT/BUILD_PROGRESS.md"
TARGET_BINARY="$OUT_DIR/$TARGET"
GN_GEN_TIMEOUT_SECS="${GN_GEN_TIMEOUT_SECS:-900}"
GN_GEN_REUSE_MAX_AGE_SECS="${GN_GEN_REUSE_MAX_AGE_SECS:-3600}"

if [[ ! -x "$CHROMIUM_PYTHON/python3" ]]; then
  CHROMIUM_PYTHON="/opt/homebrew/bin"
fi
if [[ ! -x "$AUTONINJA_BIN" ]]; then
  AUTONINJA_BIN="$(command -v autoninja || true)"
fi
if [[ -z "$AUTONINJA_BIN" && ! -x "$NINJA_BIN" ]]; then
  NINJA_BIN="$(command -v ninja || true)"
fi
BUILD_PATH="$CHROMIUM_PYTHON:$DEPOT_TOOLS:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PATH="$BUILD_PATH"

mkdir -p "$PLAN_ROOT"

write_progress() {
  local state="$1"
  local phase="$2"
  cat > "$PROGRESS_NOTE" <<EOF
# Build Progress

- state: $state
- phase: $phase
- target: $TARGET
- binary: $TARGET_BINARY
- gn_gen_timeout_secs: $GN_GEN_TIMEOUT_SECS
- ninja_jobs: $NINJA_JOBS
- checked_at: $(date '+%Y-%m-%d %H:%M:%S %Z')
EOF
}

on_exit() {
  local status="$1"
  if [[ "$status" -eq 0 ]]; then
    write_progress "completed" "done"
    return
  fi
  write_progress "failed" "exit_$status"
}

trap 'on_exit $?' EXIT

write_progress "running" "gn_gen"

cd "$CHECKOUT_ROOT"
gn_start="$(date +%s)"
set +e
timeout "$GN_GEN_TIMEOUT_SECS" ./buildtools/mac/gn gen out/libfuzzer-trend
gn_status="$?"
set -e
if [[ "$gn_status" -eq 124 ]]; then
  build_ninja_mtime="$(stat -f '%m' "$OUT_DIR/build.ninja" 2>/dev/null || echo 0)"
  build_ninja_age=$(( $(date +%s) - build_ninja_mtime))
  if [[ "$build_ninja_mtime" -eq 0 || "$build_ninja_age" -gt "$GN_GEN_REUSE_MAX_AGE_SECS" ]]; then
    exit "$gn_status"
  fi
elif [[ "$gn_status" -ne 0 ]]; then
  exit "$gn_status"
fi
write_progress "running" "ninja"
python_version="$(env PATH="$BUILD_PATH" python3 --version 2>&1 || true)"
if [[ "$python_version" != Python\ 3.1[0-9]* && "$python_version" != Python\ 3.[2-9][0-9]* ]]; then
  echo "unsupported python3 for Chromium build actions: ${python_version:-missing}" >&2
  exit 2
fi
python_path="$(env PATH="$BUILD_PATH" sh -c 'command -v python3')"
echo "build action python3: $python_version ($python_path)"
if [[ -n "$AUTONINJA_BIN" && -x "$AUTONINJA_BIN" ]]; then
  echo "build tool: $AUTONINJA_BIN -j $NINJA_JOBS"
  env PATH="$BUILD_PATH" PYTHONNOUSERSITE="$PYTHONNOUSERSITE" "$AUTONINJA_BIN" -j "$NINJA_JOBS" -C "$OUT_DIR" "$TARGET"
else
  echo "build tool: $NINJA_BIN -j $NINJA_JOBS"
  env PATH="$BUILD_PATH" PYTHONNOUSERSITE="$PYTHONNOUSERSITE" "$NINJA_BIN" -j "$NINJA_JOBS" -C "$OUT_DIR" "$TARGET"
fi
