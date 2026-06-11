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
PLAN_ROOT="$ROOT/fuzz/managed/plans/webaudio_graph_lifecycle/current"
SEED_ROOT="$PLAN_ROOT/seeds"
AI_ROOT="$PLAN_ROOT/ai"
TARGET_NAME="webaudio_graph_lifecycle"
FUZZTEST_TARGET="audio_context_manager_lifecycle_fuzztest"

mkdir -p "$PLAN_ROOT" "$AI_ROOT"

"$PYTHON_BIN" "$SCRIPTS_DIR/scaffold_seed_corpus.py" \
  --component webaudio \
  --target-family webaudio-media \
  --out-dir "$SEED_ROOT" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_lane_packet.py" \
  --lane-registry "$LANE_REGISTRY" \
  --target "$TARGET_NAME" \
  --component webaudio \
  --engine fuzztest \
  --sanitizer tsan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$SEED_ROOT/sequences" \
  --checkout "$CHECKOUT" \
  --out-json "$PLAN_ROOT/lane_packet.json" \
  --out-md "$PLAN_ROOT/lane_packet.md" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_campaign_manifest.py" \
  --component webaudio \
  --target "$TARGET_NAME" \
  --engine fuzztest \
  --sanitizer tsan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --checkout "$CHECKOUT" \
  --corpus-dir "$SEED_ROOT/sequences" \
  > "$PLAN_ROOT/campaign_manifest.json"

"$PYTHON_BIN" "$SCRIPTS_DIR/build_ai_seed_prompt.py" \
  --component webaudio \
  --target-family webaudio-media \
  --bug-class "graph lifecycle / close-after-use / thread state" \
  --prior-art "CVE-2019-13720" \
  --prior-art "public WebAudio UAF / race issues" \
  > "$AI_ROOT/seed_prompt.txt"

"$PYTHON_BIN" "$SCRIPTS_DIR/build_ai_sequence_prompt.py" \
  --component webaudio \
  --api-surface "create / start / stop / close / recreate" \
  --interesting-state "connect / disconnect / reconnect" \
  --interesting-state "close-after-use" \
  --interesting-state "node create / destroy race" \
  > "$AI_ROOT/sequence_prompt.txt"

"$PYTHON_BIN" "$SCRIPTS_DIR/discover_checkout_variants.py" \
  --checkout "$CHECKOUT" \
  --target "$FUZZTEST_TARGET" \
  > "$PLAN_ROOT/checkout_variants.json"

"$PYTHON_BIN" "$SCRIPTS_DIR/resolve_fuzz_binary.py" \
  --checkout "$CHECKOUT" \
  --target "$FUZZTEST_TARGET" \
  --sanitizer tsan \
  --binary-candidate "$CHECKOUT/out/fuzztest/$FUZZTEST_TARGET" \
  --binary-candidate "$CHECKOUT/out/asan-vrp/$FUZZTEST_TARGET" \
  > "$PLAN_ROOT/resolve_binary.json"

RESOLVED_BINARY="$("$PYTHON_BIN" - <<'PY' "$PLAN_ROOT/resolve_binary.json"
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
matches = data.get("matches", [])
print(matches[0]["binary"] if matches else "")
PY
)"

cat > "$PLAN_ROOT/NEXT_STEPS.md" <<EOF
# WebAudio Graph Lifecycle Main Lane

- checkout: $CHECKOUT
- target: $FUZZTEST_TARGET
- resolved_binary: ${RESOLVED_BINARY:-unresolved}

## 준비된 산출물

- lane packet: lane_packet.json / lane_packet.md
- campaign manifest: campaign_manifest.json
- seed scaffold: seeds/
- AI prompts: ai/seed_prompt.txt, ai/sequence_prompt.txt
- variant scan: checkout_variants.json
- binary resolution: resolve_binary.json

## 다음 실행 명령

1. \`autoninja -C $CHECKOUT/out/fuzztest $FUZZTEST_TARGET\`
2. \`$CHECKOUT/third_party/ninja/ninja -C $CHECKOUT/out/asan-vrp $FUZZTEST_TARGET\`
3. \`bash $SCRIPTS_DIR/run_fuzztest_target.sh --binary <resolved-binary> --component webaudio --target $TARGET_NAME --sanitizer tsan --platform desktop --artifact-root $ROOT/fuzz/managed/artifacts --lane-registry $LANE_REGISTRY\`
EOF

cat > "$PLAN_ROOT/BUILD_STATUS.md" <<EOF
# Build Status

- target: $FUZZTEST_TARGET
- current_host_policy: do not run broad Chromium rebuilds on the same host as long-running fuzz lanes
- preferred_variants:
  - $CHECKOUT/out/fuzztest
  - $CHECKOUT/out/asan-vrp

## Notes

- this target is a lightweight lifecycle bridge around AudioContextManagerImpl
- it is not the final full Blink graph race lane, but it is a better TSan-oriented starting point than the older mojolpm-only path
EOF

if [[ -n "$RESOLVED_BINARY" && -x "$RESOLVED_BINARY" ]]; then
  bash "$SCRIPTS_DIR/run_fuzztest_target.sh" \
    --binary "$RESOLVED_BINARY" \
    --component webaudio \
    --target "$TARGET_NAME" \
    --sanitizer tsan \
    --platform desktop \
    --artifact-root "$ROOT/fuzz/managed/artifacts" \
    --lane-registry "$LANE_REGISTRY" \
    --dry-run \
    > "$PLAN_ROOT/dry_run.txt"
fi

echo "$PLAN_ROOT"
