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
PLAN_ROOT="$ROOT/fuzz/managed/plans/dawn_wire_lifecycle_sequence/current"
SEED_ROOT="$PLAN_ROOT/seeds"
AI_ROOT="$PLAN_ROOT/ai"
TARGET_NAME="dawn_wire_lifecycle_sequence"
BINARY_CANDIDATE="$CHECKOUT/out/libfuzzer-trend/dawn_wire_lifecycle_sequence_fuzztest_DawnWireLifecycleSequenceFuzzTest_HandlesWireLifecycleSequence_fuzzer"

mkdir -p "$PLAN_ROOT" "$AI_ROOT"

"$PYTHON_BIN" "$SCRIPTS_DIR/scaffold_seed_corpus.py" \
  --component gpu \
  --target-family gpu-wire \
  --out-dir "$SEED_ROOT" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_lane_packet.py" \
  --lane-registry "$LANE_REGISTRY" \
  --target "$TARGET_NAME" \
  --component gpu \
  --engine fuzztest \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$ROOT/fuzz/corpus/dawn_wire_lifecycle_sequence" \
  --binary "$BINARY_CANDIDATE" \
  --checkout "$CHECKOUT" \
  --out-json "$PLAN_ROOT/lane_packet.json" \
  --out-md "$PLAN_ROOT/lane_packet.md" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_campaign_manifest.py" \
  --component gpu \
  --target "$TARGET_NAME" \
  --engine fuzztest \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --checkout "$CHECKOUT" \
  --corpus-dir "$ROOT/fuzz/corpus/dawn_wire_lifecycle_sequence" \
  --binary "$BINARY_CANDIDATE" \
  > "$PLAN_ROOT/campaign_manifest.json"

"$PYTHON_BIN" "$SCRIPTS_DIR/build_ai_seed_prompt.py" \
  --component gpu \
  --target-family gpu-wire \
  --bug-class "wire lifecycle / callback reentrancy / stale handle reuse" \
  --prior-art "destroy during callback" \
  --prior-art "mapAsync / unmap lifecycle" \
  --prior-art "queue submit on invalid object" \
  > "$AI_ROOT/seed_prompt.txt"

"$PYTHON_BIN" "$SCRIPTS_DIR/build_ai_sequence_prompt.py" \
  --component gpu \
  --api-surface "createBuffer mapAsync unmap destroy submit reset" \
  --interesting-state "mapAsync while destroyed" \
  --interesting-state "double unmap" \
  --interesting-state "submit on destroyed queue" \
  --interesting-state "callback during reentrancy" \
  > "$AI_ROOT/sequence_prompt.txt"

cat > "$PLAN_ROOT/STRATEGY.md" <<EOF
# Dawn Wire Lifecycle Lane Strategy

- primary target: $TARGET_NAME
- theme: callback reentrancy + wire lifecycle + stale object reuse

## 핵심 메모

- WebGPU/Dawn는 parser보다 ownership과 callback ordering을 우선 본다
- hot loop보다 typed sequence와 lifecycle cluster를 더 믿는다
- destroy/reset/mapAsync 경계를 같은 lane에서 묶는다
- renderer-facing API와 wire/server lifecycle의 간극을 같이 본다

## 참고

- chromium-research-wiki/wiki/packs/gpu-graphics.md
- chromium-fuzzing-lab/references/recipes-gpu.md
EOF

echo "$PLAN_ROOT"
