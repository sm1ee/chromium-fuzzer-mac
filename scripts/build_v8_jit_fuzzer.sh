#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
SRC="$ROOT/src"
DEPOT_TOOLS="/Users/bugclaw/.openclaw/workspace/depot_tools"
OUT_DIR="${OUT_DIR:-$SRC/out/libfuzzer-trend}"
TARGET="${TARGET:-v8_script_parser_fuzzer}"
NINJA_JOBS="${NINJA_JOBS:-2}"
MAX_LOAD_1M="${MAX_LOAD_1M:-6}"
AUTONINJA_BIN="${AUTONINJA_BIN:-$DEPOT_TOOLS/autoninja}"
NINJA_BIN="${NINJA_BIN:-$SRC/third_party/ninja/ninja}"
CHROMIUM_PYTHON="$DEPOT_TOOLS/bootstrap-2@3.11.8.chromium.35_bin/python3/bin"
PREFER_AUTONINJA="${PREFER_AUTONINJA:-0}"

export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"
if [[ ! -x "$CHROMIUM_PYTHON/python3" ]]; then
  CHROMIUM_PYTHON="/opt/homebrew/bin"
fi
export PATH="$CHROMIUM_PYTHON:$DEPOT_TOOLS:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export HOME="$ROOT/.home"
export XDG_CACHE_HOME="$ROOT/.cache"

load_1m() {
  if [[ -r /proc/loadavg ]]; then
    awk '{print $1}' /proc/loadavg
    return 0
  fi
  uptime | sed -E 's/.*load averages?: //' | cut -d, -f1 | tr -d ' '
}

load_too_high() {
  local current
  current="$(load_1m)"
  awk -v current="$current" -v max="$MAX_LOAD_1M" 'BEGIN { exit((current + 0) > (max + 0) ? 0 : 1) }'
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

if [[ ! -d "$OUT_DIR" ]]; then
  log "error: output dir missing: $OUT_DIR"
  exit 2
fi
if load_too_high; then
  log "skip: load too high for build, max_load_1m=$MAX_LOAD_1M"
  exit 75
fi

BUILD_CMD=()
if [[ "$PREFER_AUTONINJA" != "1" && -x "$NINJA_BIN" ]]; then
  BUILD_CMD=("$NINJA_BIN" -j "$NINJA_JOBS")
elif [[ -x "$AUTONINJA_BIN" ]]; then
  BUILD_CMD=("$AUTONINJA_BIN" -j "$NINJA_JOBS")
elif [[ -x "$NINJA_BIN" ]]; then
  BUILD_CMD=("$NINJA_BIN" -j "$NINJA_JOBS")
else
  log "error: no usable autoninja or ninja found"
  exit 2
fi

log "building target=$TARGET out=$OUT_DIR jobs=$NINJA_JOBS"
"${BUILD_CMD[@]}" -C "$OUT_DIR" "$TARGET"

binary="$OUT_DIR/$TARGET"
if [[ -x "$binary" ]]; then
  stat -f 'built_binary=%N mtime=%Sm size=%z' -t '%Y-%m-%d %H:%M:%S' "$binary" 2>/dev/null ||
    stat -c 'built_binary=%n mtime=%y size=%s' "$binary" 2>/dev/null ||
    true
else
  log "warning: build returned but binary is not executable: $binary"
fi
