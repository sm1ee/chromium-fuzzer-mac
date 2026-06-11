#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
SKILL_ROOT="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab"
STATEFUL_BINARY="$ROOT/src/out/libfuzzer-trend/indexed_db_leveldb_coding_sequence_fuzztest_IndexedDbLevelDbCodingSequenceFuzzTest_IndexedDbCodingStatefulSequence_fuzzer"
STATEFUL_LABEL="com.bugclaw.chromium-fuzz-indexeddb-stateful"
PARSER_LABEL="com.bugclaw.chromium-fuzz-indexeddb"
LANE_REGISTRY="$ROOT/fuzz/managed/lane_registry.json"
LOG_DIR="$ROOT/fuzz/logs"
PROMOTE_NOTE="$ROOT/fuzz/managed/plans/indexeddb_stateful_sequence/current/PROMOTION_STATUS.md"
UID_VALUE="$(id -u)"
PARSER_BINARY="$ROOT/src/out/libfuzzer-trend/indexed_db_leveldb_coding_decodeidbkey_fuzzer"

mkdir -p "$LOG_DIR" "$(dirname "$PROMOTE_NOTE")"

stop_parser_roots() {
  local pid pids
  pids="$(ps -eo pid=,ppid=,args= | awk -v binary="$PARSER_BINARY" '
    $2 == 1 {
      args = "";
      for (i = 3; i <= NF; i++) {
        args = args (i == 3 ? "" : " ") $i
      }
      if (index(args, binary) > 0) {
        print $1
      }
    }
  ')"
  [[ -n "${pids// /}" ]] || return 0
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
}

if [[ ! -x "$STATEFUL_BINARY" ]]; then
  launchctl bootout "gui/$UID_VALUE/$STATEFUL_LABEL" >/dev/null 2>&1 || true
  cat > "$PROMOTE_NOTE" <<EOF
# Promotion Status

- state: waiting_for_binary
- launcher: stopped_until_binary_ready
- label: $STATEFUL_LABEL
- binary: $STATEFUL_BINARY
- checked_at: $(date '+%Y-%m-%d %H:%M:%S %Z')
EOF
  exit 0
fi

if launchctl print "gui/$UID_VALUE/$STATEFUL_LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$UID_VALUE/$STATEFUL_LABEL"
  launchctl bootout "gui/$UID_VALUE/$PARSER_LABEL" >/dev/null 2>&1 || true
  stop_parser_roots
  cat > "$PROMOTE_NOTE" <<EOF
# Promotion Status

- state: restarted_existing
- label: $STATEFUL_LABEL
- binary: $STATEFUL_BINARY
- checked_at: $(date '+%Y-%m-%d %H:%M:%S %Z')
EOF
  exit 0
fi

launchctl bootstrap "gui/$UID_VALUE" "/Users/bugclaw/Library/LaunchAgents/${STATEFUL_LABEL}.plist"
launchctl kickstart -k "gui/$UID_VALUE/$STATEFUL_LABEL"

launchctl bootout "gui/$UID_VALUE/$PARSER_LABEL" >/dev/null 2>&1 || true
stop_parser_roots

cat > "$PROMOTE_NOTE" <<EOF
# Promotion Status

- state: promoted
- label: $STATEFUL_LABEL
- binary: $STATEFUL_BINARY
- lane_registry: $LANE_REGISTRY
- promoted_at: $(date '+%Y-%m-%d %H:%M:%S %Z')
EOF
