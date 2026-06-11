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
PLAN_ROOT="$ROOT/fuzz/managed/plans/angle_pixelbytes_width/current"
SEED_ROOT="$PLAN_ROOT/seeds"
AI_ROOT="$PLAN_ROOT/ai"
TARGET_NAME="angle_pixelbytes_width_fuzzer"

mkdir -p "$PLAN_ROOT" "$AI_ROOT"

"$PYTHON_BIN" "$SCRIPTS_DIR/scaffold_seed_corpus.py" \
  --component gpu \
  --target-family gpu-bridge \
  --out-dir "$SEED_ROOT" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_lane_packet.py" \
  --lane-registry "$LANE_REGISTRY" \
  --target "$TARGET_NAME" \
  --component gpu \
  --engine libfuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$ROOT/fuzz/corpus/angle_pixelbytes_width" \
  --binary "$CHECKOUT/out/libfuzzer-trend/angle_pixelbytes_width_fuzzer" \
  --checkout "$CHECKOUT" \
  --out-json "$PLAN_ROOT/lane_packet.json" \
  --out-md "$PLAN_ROOT/lane_packet.md" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_campaign_manifest.py" \
  --component gpu \
  --target "$TARGET_NAME" \
  --engine libfuzzer \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --checkout "$CHECKOUT" \
  --corpus-dir "$ROOT/fuzz/corpus/angle_pixelbytes_width" \
  --binary "$CHECKOUT/out/libfuzzer-trend/angle_pixelbytes_width_fuzzer" \
  > "$PLAN_ROOT/campaign_manifest.json"

"$PYTHON_BIN" "$SCRIPTS_DIR/build_ai_seed_prompt.py" \
  --component gpu \
  --target-family gpu-bridge \
  --bug-class "staging allocation undersize / row pitch overflow" \
  --prior-art "ANGLE Vulkan staging size overflow" \
  --prior-art "pixelBytes * width intermediate wrap" \
  --prior-art "undersized staging buffer followed by full write" \
  > "$AI_ROOT/seed_prompt.txt"

cat > "$PLAN_ROOT/STRATEGY.md" <<EOF
# ANGLE PixelBytes Targeted Lane

- primary target: $TARGET_NAME
- theme: vk_helpers.cpp stageSubresourceUpdateImpl arithmetic hazard

## 핵심 메모

- blind translator 대신 renderer/vulkan staging 경계에 직접 붙는다
- width/height/depth/pixelBytes를 integer boundary 위주로 흔든다
- allocation undersize와 full write 간극만 남기는 쪽으로 minimization 한다

## 참고

- _audit/DEEPDIVE_471638853_2026-04-09.md
- _audit/ANGLE_PIXELBYTES_HARNESS_2026-04-13.md
EOF

echo "$PLAN_ROOT"
