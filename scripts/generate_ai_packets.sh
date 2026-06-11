#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"

SKILL_ROOT="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab/scripts"
OUT="/Users/bugclaw/.openclaw/workspace/chromium-vrp/fuzz/managed/ai"
PYTHON_BIN="${PYTHON_BIN:-/Users/bugclaw/.openclaw/workspace/depot_tools/bootstrap-2@3.11.8.chromium.35_bin/python3/bin/python3}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="/opt/homebrew/bin/python3"
fi
mkdir -p "$OUT"

"$PYTHON_BIN" "$SKILL_ROOT/build_ai_seed_prompt.py" \
  --component indexeddb \
  --target-family indexeddb-storage \
  --bug-class "state desynchronization / ordering" \
  --prior-art "IndexedDB desynchronization" \
  --prior-art "IndexedDB use-after-free" \
  >"$OUT/indexeddb_seed_prompt.txt"

"$PYTHON_BIN" "$SKILL_ROOT/build_ai_sequence_prompt.py" \
  --component indexeddb \
  --api-surface "open, versionchange, transaction, close, callback" \
  --interesting-state "versionchange during active transaction" \
  --interesting-state "close before callback completes" \
  --interesting-state "stale handle reuse after reopen" \
  >"$OUT/indexeddb_sequence_prompt.txt"

"$PYTHON_BIN" "$SKILL_ROOT/build_ai_seed_prompt.py" \
  --component mojo \
  --target-family mojo-ipc \
  --bug-class "lifecycle race / route capability / user message parsing" \
  --prior-art "Breaking the Chrome Sandbox with Mojo" \
  --prior-art "ReceiverSet dispatch use-after-free" \
  >"$OUT/mojo_seed_prompt.txt"

"$PYTHON_BIN" "$SKILL_ROOT/build_ai_sequence_prompt.py" \
  --component mojo \
  --api-surface "message, route, disconnect, reconnect, OnError" \
  --interesting-state "message after disconnect" \
  --interesting-state "reused route after reconnect" \
  --interesting-state "message after OnError" \
  >"$OUT/mojo_sequence_prompt.txt"

echo "ai packets written to $OUT"
