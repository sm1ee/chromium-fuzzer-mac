#!/bin/bash
# WasmGC sandbox-boundary fuzzing runner.
# Generates corpus, then runs each case under d8 --sandbox-fuzzing.
# Designed for Linux (sandbox crash filter is Linux-only).
#
# Usage:
#   ./run_wasm_sandbox_fuzz.sh [d8_path] [v8_root]
#
# Example:
#   ./run_wasm_sandbox_fuzz.sh ~/work/chromium-vrp-current/src/out/sandbox-testing-asan/d8 ~/work/chromium-vrp-current/src/v8

set -euo pipefail

D8="${1:-$(dirname "$0")/../chromium-vrp-current/src/out/sandbox-testing-asan/d8}"
V8_ROOT="${2:-$(dirname "$0")/../chromium-vrp-current/src/v8}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORPUS_DIR="${SCRIPT_DIR}/corpus/wasm_sandbox_boundary"
HITS_DIR="${SCRIPT_DIR}/hits/wasm_sandbox_boundary"
LOG="${SCRIPT_DIR}/logs/wasm_sandbox_fuzz.log"
COUNT="${WASM_SBX_COUNT:-200}"
SEED="${WASM_SBX_SEED:-$$}"

mkdir -p "$CORPUS_DIR" "$HITS_DIR" "$(dirname "$LOG")"

if [ ! -x "$D8" ]; then
    echo "[ERROR] d8 not found at $D8" | tee -a "$LOG"
    exit 1
fi

if [ ! -f "$V8_ROOT/test/mjsunit/wasm/wasm-module-builder.js" ]; then
    echo "[ERROR] V8 root not found at $V8_ROOT" | tee -a "$LOG"
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting wasm sandbox boundary fuzz (seed=$SEED count=$COUNT)" | tee -a "$LOG"

python3 "$SCRIPT_DIR/gen_wasm_sandbox_boundary_corpus.py" \
    --out-dir "$CORPUS_DIR" --count "$COUNT" --seed "$SEED" 2>&1 | tee -a "$LOG"

TOTAL=0
VIOLATIONS=0

cd "$V8_ROOT"

for js_file in "$CORPUS_DIR"/sbx_*.js; do
    TOTAL=$((TOTAL + 1))
    basename_js=$(basename "$js_file")

    output=$("$D8" --sandbox-fuzzing "$js_file" 2>&1) || true

    if echo "$output" | grep -q "V8 sandbox violation"; then
        VIOLATIONS=$((VIOLATIONS + 1))
        echo "[HIT] $basename_js — sandbox violation!" | tee -a "$LOG"
        cp "$js_file" "$HITS_DIR/${basename_js%.js}_violation_$(date +%s).js"
        echo "$output" > "$HITS_DIR/${basename_js%.js}_violation_$(date +%s).log"
    elif echo "$output" | grep -qiE "AddressSanitizer|heap-buffer-overflow|heap-use-after-free|SEGV"; then
        VIOLATIONS=$((VIOLATIONS + 1))
        echo "[ASAN] $basename_js — sanitizer hit!" | tee -a "$LOG"
        cp "$js_file" "$HITS_DIR/${basename_js%.js}_asan_$(date +%s).js"
        echo "$output" > "$HITS_DIR/${basename_js%.js}_asan_$(date +%s).log"
    fi

    if [ $((TOTAL % 50)) -eq 0 ]; then
        echo "[$(date '+%H:%M:%S')] Progress: $TOTAL/$COUNT (violations=$VIOLATIONS)" | tee -a "$LOG"
    fi
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done. total=$TOTAL violations=$VIOLATIONS" | tee -a "$LOG"
