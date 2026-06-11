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
PLAN_ROOT="$ROOT/fuzz/managed/plans/indexeddb_stateful_sequence/current"
SEED_ROOT="$PLAN_ROOT/seeds"
AI_ROOT="$PLAN_ROOT/ai"
TARGET_NAME="indexeddb_stateful_sequence"
FUZZTEST_TARGET="indexed_db_leveldb_coding_sequence_fuzztest"

mkdir -p "$PLAN_ROOT" "$AI_ROOT"

"$PYTHON_BIN" "$SCRIPTS_DIR/scaffold_seed_corpus.py" \
  --component indexeddb \
  --target-family indexeddb-storage \
  --out-dir "$SEED_ROOT" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_lane_packet.py" \
  --lane-registry "$LANE_REGISTRY" \
  --target "$TARGET_NAME" \
  --component indexeddb \
  --engine fuzztest \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --corpus-dir "$SEED_ROOT/sequences" \
  --checkout "$CHECKOUT" \
  --out-json "$PLAN_ROOT/lane_packet.json" \
  --out-md "$PLAN_ROOT/lane_packet.md" >/dev/null

"$PYTHON_BIN" "$SCRIPTS_DIR/build_campaign_manifest.py" \
  --component indexeddb \
  --target "$TARGET_NAME" \
  --engine fuzztest \
  --sanitizer asan \
  --platform desktop \
  --artifact-root "$ROOT/fuzz/managed/artifacts" \
  --checkout "$CHECKOUT" \
  --corpus-dir "$SEED_ROOT/sequences" \
  > "$PLAN_ROOT/campaign_manifest.json"

"$PYTHON_BIN" "$SCRIPTS_DIR/build_ai_seed_prompt.py" \
  --component indexeddb \
  --target-family indexeddb-storage \
  --bug-class "state desynchronization / stale handle reuse" \
  --prior-art "IndexedDB desynchronization" \
  --prior-art "IndexedDB use-after-free" \
  > "$AI_ROOT/seed_prompt.txt"

"$PYTHON_BIN" "$SCRIPTS_DIR/build_ai_sequence_prompt.py" \
  --component indexeddb \
  --api-surface "open / upgrade / versionchange / transaction / close" \
  --interesting-state "open -> upgrade -> abort" \
  --interesting-state "transaction -> close -> callback" \
  --interesting-state "stale handle reuse" \
  > "$AI_ROOT/sequence_prompt.txt"

"$PYTHON_BIN" "$SCRIPTS_DIR/discover_checkout_variants.py" \
  --checkout "$CHECKOUT" \
  --target "$FUZZTEST_TARGET" \
  > "$PLAN_ROOT/checkout_variants.json"

"$PYTHON_BIN" "$SCRIPTS_DIR/resolve_fuzz_binary.py" \
  --checkout "$CHECKOUT" \
  --target "$FUZZTEST_TARGET" \
  --sanitizer asan \
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
# IndexedDB Stateful Main Lane

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
2. \`autoninja -C $CHECKOUT/out/fuzz-asan-indexeddb $FUZZTEST_TARGET\`
3. \`bash $SCRIPTS_DIR/run_fuzztest_target.sh --binary <resolved-binary> --component indexeddb --target $TARGET_NAME --sanitizer asan --platform desktop --artifact-root $ROOT/fuzz/managed/artifacts --lane-registry $LANE_REGISTRY\`
EOF

if [[ -n "$RESOLVED_BINARY" && -x "$RESOLVED_BINARY" ]]; then
  bash "$SCRIPTS_DIR/run_fuzztest_target.sh" \
    --binary "$RESOLVED_BINARY" \
    --component indexeddb \
    --target "$TARGET_NAME" \
    --sanitizer asan \
    --platform desktop \
    --artifact-root "$ROOT/fuzz/managed/artifacts" \
    --lane-registry "$LANE_REGISTRY" \
    --dry-run \
    > "$PLAN_ROOT/dry_run.txt"
fi

echo "$PLAN_ROOT"
