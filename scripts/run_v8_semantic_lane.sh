#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
CHECKOUT="$ROOT/src"
SKILL_ROOT="${CHROMIUM_FUZZING_LAB_SKILL_ROOT:-/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab}"
if [[ ! -d "$SKILL_ROOT/scripts" ]]; then
  SKILL_ROOT="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab"
fi
SCRIPTS_DIR="$SKILL_ROOT/scripts"
PYTHON_BIN="${PYTHON_BIN:-/Users/bugclaw/.openclaw/workspace/depot_tools/bootstrap-2@3.11.8.chromium.35_bin/python3/bin/python3}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="/opt/homebrew/bin/python3"
fi
LANE_REGISTRY="$ROOT/fuzz/managed/lane_registry.json"
PLAN_ROOT="$ROOT/fuzz/managed/plans/v8_semantic_jit/current"
SEED_ROOT="$PLAN_ROOT/seeds"
SEED_INPUT_DIR="$SEED_ROOT/inputs"
AI_ROOT="$PLAN_ROOT/ai"
TARGET_NAME="v8_script_parser_fuzzer"
CORPUS_DIR="$ROOT/fuzz/corpus/v8_script_parser"

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

install_seed() {
  local name="$1"
  local target="$SEED_INPUT_DIR/$name.js"
  local corpus_target="$CORPUS_DIR/$name.js"
  shift
  if [[ ! -f "$target" ]]; then
    printf '%s\n' "$@" >"$target"
  fi
  if [[ ! -f "$corpus_target" ]]; then
    cp "$target" "$corpus_target"
  fi
}

BINARY="$(
  first_existing_binary \
    "$CHECKOUT/out/libfuzzer-current/v8_script_parser_fuzzer" \
    "$CHECKOUT/out/libfuzzer-narrow-linux/v8_script_parser_fuzzer" \
    "$CHECKOUT/out/libfuzzer-trend/v8_script_parser_fuzzer"
)"

mkdir -p "$PLAN_ROOT" "$AI_ROOT" "$SEED_INPUT_DIR" "$CORPUS_DIR"

"$PYTHON_BIN" "$SCRIPTS_DIR/scaffold_seed_corpus.py" \
  --component v8 \
  --target-family v8-jit \
  --out-dir "$SEED_ROOT" >/dev/null

install_seed "map_transition_side_effect" \
  '"use strict";' \
  'function f(o, k) { let x = o[k] | 0; o.extra = 1; return (x + (o[k] | 0)) | 0; }' \
  'let o = {a: 1}; for (let i = 0; i < 128; i++) f(o, "a"); print(f(o, "a"));'
install_seed "rab_resize_length" \
  '"use strict";' \
  'try { let b = new ArrayBuffer(64, {maxByteLength: 128}); let a = new Uint8Array(b);' \
  'function f(i) { if (i < a.length) return a[i] | 0; return -1; } for (let i = 0; i < 128; i++) f(i & 7); b.resize(128); print(f(96)); } catch (e) { print(-2); }'
install_seed "closure_state_mutation" \
  '"use strict";' \
  'let x = 0; function f(v) { x = (x + v) | 0; return x; } for (let i = 0; i < 128; i++) f(i); print(f(-2147483648));'
install_seed "numeric_boundary" \
  '"use strict";' \
  'function f(x) { return (((x | 0) + 1) ^ (x >>> 1)) | 0; } for (let i = 0; i < 256; i++) f(i); print(f(2147483647));'

"$PYTHON_BIN" "$SCRIPTS_DIR/build_lane_packet.py" \
  --lane-registry "$LANE_REGISTRY" \
  --target "$TARGET_NAME" \
  --component v8 \
  --engine libfuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$CORPUS_DIR" \
  --binary "$BINARY" \
  --checkout "$CHECKOUT" \
  --out-json "$PLAN_ROOT/lane_packet.json" \
  --out-md "$PLAN_ROOT/lane_packet.md" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_campaign_manifest.py" \
  --component v8 \
  --target "$TARGET_NAME" \
  --engine libfuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --checkout "$CHECKOUT" \
  --corpus-dir "$CORPUS_DIR" \
  --binary "$BINARY" \
  > "$PLAN_ROOT/campaign_manifest.json"

"$PYTHON_BIN" "$SCRIPTS_DIR/build_ai_seed_prompt.py" \
  --component v8 \
  --target-family v8-jit \
  --bug-class "semantic transform / map transition / weak primitive preservation" \
  --prior-art "SET (Semantic Equivalent Transform)" \
  --prior-art "Map deprecation / side-effect modelling" \
  --prior-art "Weak primitive should not be discarded" \
  > "$AI_ROOT/seed_prompt.txt"

cat > "$PLAN_ROOT/STRATEGY.md" <<EOF
# V8 Semantic Lane Strategy

- primary target: v8_script_parser_fuzzer
- theme: semantic-preserving transform over raw coverage greed

## 핵심 메모

- semantic equivalent transform 으로 seed quality를 유지한다
- weak primitive 로 보이는 snippet도 버리지 않는다
- coverage 증가와 bug proximity를 동일시하지 않는다
- worker reset / delayed sync 를 재기동 시 고려한다

## 위키 근거

- chromium-research-wiki/wiki/packs/v8-jit-core.md
- chromium-research-wiki/wiki/talks/docs/mutational-grammar-fuzzing-2026.md
- chromium-research-wiki/wiki/talks/blackhat/pwning-chrome-2016-to-2019-2019.md
EOF

echo "$PLAN_ROOT"
