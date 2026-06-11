#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
CHECKOUT="$ROOT/src"
SKILL_ROOT="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab"
SCRIPTS_DIR="$SKILL_ROOT/scripts"
PYTHON_BIN="${PYTHON_BIN:-/Users/bugclaw/.openclaw/workspace/depot_tools/bootstrap-2@3.11.8.chromium.35_bin/python3/bin/python3}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="/opt/homebrew/bin/python3"
fi
LANE_REGISTRY="$ROOT/fuzz/managed/lane_registry.json"
PLAN_ROOT="$ROOT/fuzz/managed/plans/graphics_precision/current"
SEED_ROOT="$PLAN_ROOT/seeds"
AI_ROOT="$PLAN_ROOT/ai"
PRIMARY_TARGET="tint_wgsl_fuzzer"
SECONDARY_TARGET="angle_translator_fuzzer"

mkdir -p "$PLAN_ROOT" "$AI_ROOT"

"$PYTHON_BIN" "$SCRIPTS_DIR/scaffold_seed_corpus.py" \
  --component gpu \
  --target-family gpu-compiler \
  --out-dir "$SEED_ROOT" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_lane_packet.py" \
  --lane-registry "$LANE_REGISTRY" \
  --target "$PRIMARY_TARGET" \
  --component gpu \
  --engine libfuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$ROOT/fuzz/corpus/tint_wgsl" \
  --binary "$CHECKOUT/out/libfuzzer-trend/tint_wgsl_fuzzer" \
  --checkout "$CHECKOUT" \
  --out-json "$PLAN_ROOT/lane_packet.json" \
  --out-md "$PLAN_ROOT/lane_packet.md" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_campaign_manifest.py" \
  --component gpu \
  --target "$PRIMARY_TARGET" \
  --engine libfuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --checkout "$CHECKOUT" \
  --corpus-dir "$ROOT/fuzz/corpus/tint_wgsl" \
  --binary "$CHECKOUT/out/libfuzzer-trend/tint_wgsl_fuzzer" \
  > "$PLAN_ROOT/campaign_manifest.json"

"$PYTHON_BIN" "$SCRIPTS_DIR/build_ai_seed_prompt.py" \
  --component gpu \
  --target-family gpu-compiler \
  --bug-class "precision bug / shader translator / bridge issue" \
  --prior-art "Heap Feng Shader" \
  --prior-art "Drawing Outside the Box" \
  --prior-art "SwiftShader / graphics bridge as separate attack surface" \
  > "$AI_ROOT/seed_prompt.txt"

cat > "$PLAN_ROOT/STRATEGY.md" <<EOF
# Graphics Precision Lane Strategy

- primary target: $PRIMARY_TARGET
- secondary target: $SECONDARY_TARGET

## 핵심 메모

- shader compiler / translator 와 image / format bridge를 분리해서 본다
- valid shader corpus와 spec-bending precision variant를 같이 유지한다
- ANGLE은 noisy fallback, Tint는 structured primary lane으로 본다
- graphics correctness bug도 infoleak/corruption primitive 관점으로 본다

## 위키 근거

- chromium-research-wiki/wiki/talks/writeups/p0-heap-feng-shader-2018.md
- chromium-fuzzing-lab/references/recipes-gpu.md
- chromium-fuzzing-lab/references/component-target-matrix.md
EOF

echo "$PLAN_ROOT"
