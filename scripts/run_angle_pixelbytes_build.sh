#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
CHECKOUT="$ROOT/src"
DEPOT_TOOLS="/Users/bugclaw/.openclaw/workspace/depot_tools"
CHROMIUM_PYTHON="$DEPOT_TOOLS/bootstrap-2@3.11.8.chromium.35_bin/python3/bin"
AUTONINJA_BIN="${AUTONINJA_BIN:-$DEPOT_TOOLS/autoninja}"
NINJA_BIN="${NINJA_BIN:-$CHECKOUT/third_party/ninja/ninja}"
NINJA_JOBS="${NINJA_JOBS:-6}"
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

/bin/bash "$ROOT/fuzz/run_angle_pixelbytes_lane.sh" >/dev/null

cd "$CHECKOUT"
if [[ -n "$AUTONINJA_BIN" && -x "$AUTONINJA_BIN" ]]; then
  nice -n 15 "$AUTONINJA_BIN" -j "$NINJA_JOBS" -C out/libfuzzer-trend angle_pixelbytes_width_fuzzer
elif [[ -n "$NINJA_BIN" && -x "$NINJA_BIN" ]]; then
  nice -n 15 "$NINJA_BIN" -j "$NINJA_JOBS" -C out/libfuzzer-trend angle_pixelbytes_width_fuzzer
else
  echo "error: no usable autoninja or ninja found" >&2
  exit 2
fi
