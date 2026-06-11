#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
SRC="$ROOT/src"
DEPOT_TOOLS="/Users/bugclaw/.openclaw/workspace/depot_tools"
CHROMIUM_PYTHON="$DEPOT_TOOLS/bootstrap-2@3.11.8.chromium.35_bin/python3/bin"
AUTONINJA_BIN="${AUTONINJA_BIN:-$DEPOT_TOOLS/autoninja}"
NINJA_BIN="${NINJA_BIN:-$SRC/third_party/ninja/ninja}"
NINJA_JOBS="${NINJA_JOBS:-6}"

export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"
if [[ ! -x "$CHROMIUM_PYTHON/python3" ]]; then
  CHROMIUM_PYTHON="/opt/homebrew/bin"
fi
if [[ ! -x "$AUTONINJA_BIN" ]]; then
  AUTONINJA_BIN="$(command -v autoninja || true)"
fi
if [[ ! -x "$NINJA_BIN" ]]; then
  NINJA_BIN="$(command -v ninja || true)"
fi
export PATH="$CHROMIUM_PYTHON:$DEPOT_TOOLS:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

export HOME="$ROOT/.home"
export XDG_CACHE_HOME="$ROOT/.cache"

TARGETS=(
  "v8_script_parser_fuzzer"
  "angle_translator_fuzzer"
  "tint_wgsl_fuzzer"
  "webcodecs_video_decoder_fuzzer"
  "css_parser_fast_paths_fuzzer"
  "stylesheet_contents_fuzzer"
  "skia_path_fuzzer"
)

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

failures=()
BUILD_CMD=()
if [[ -n "$AUTONINJA_BIN" && -x "$AUTONINJA_BIN" ]]; then
  BUILD_CMD=("$AUTONINJA_BIN" -j "$NINJA_JOBS")
elif [[ -n "$NINJA_BIN" && -x "$NINJA_BIN" ]]; then
  BUILD_CMD=("$NINJA_BIN" -j "$NINJA_JOBS")
else
  log "error: no usable autoninja or ninja found"
  exit 2
fi

for target in "${TARGETS[@]}"; do
  log "building $target"
  if ! "${BUILD_CMD[@]}" -C "$SRC/out/libfuzzer-trend" "$target"; then
    log "build failed: $target"
    failures+=("$target")
  fi
done

if (( ${#failures[@]} > 0 )); then
  log "failed targets: ${failures[*]}"
  exit 1
fi
