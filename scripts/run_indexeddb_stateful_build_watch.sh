#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
LOG_FILE="$ROOT/fuzz/logs/indexeddb_stateful_build.stdout.log"
NOTE_FILE="$ROOT/fuzz/managed/plans/indexeddb_stateful_sequence/current/BUILD_PROGRESS.md"
WRAPPER_LABEL="com.bugclaw.chromium-build-indexeddb-stateful"
STATEFUL_BINARY="$ROOT/src/out/libfuzzer-trend/indexed_db_leveldb_coding_sequence_fuzztest_IndexedDbLevelDbCodingSequenceFuzzTest_IndexedDbCodingStatefulSequence_fuzzer"
PYTHON_BIN="${PYTHON_BIN:-/Users/bugclaw/.openclaw/workspace/depot_tools/bootstrap-2@3.11.8.chromium.35_bin/python3/bin/python3}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="/opt/homebrew/bin/python3"
fi
UID_VALUE="$(id -u)"

mkdir -p "$(dirname "$NOTE_FILE")"

load_1m() {
  uptime | awk -F'load averages: ' '{print $2}' | awk '{gsub(/^ +| +$/,"",$1); print $1}'
}

swap_free_mb() {
  /usr/sbin/sysctl vm.swapusage | awk -F'free = ' '{print $2}' | awk '{gsub("M","",$1); print int($1)}'
}

wrapper_state="stopped"
wrapper_pid="-"
wrapper_last_exit="-"
if launchctl print "gui/$UID_VALUE/$WRAPPER_LABEL" >/dev/null 2>&1; then
  wrapper_state="$(launchctl print "gui/$UID_VALUE/$WRAPPER_LABEL" | awk -F'= ' '/state =/ {print $2; exit}')"
  wrapper_pid="$(launchctl print "gui/$UID_VALUE/$WRAPPER_LABEL" | awk -F'= ' '/pid =/ {print $2; exit}')"
  wrapper_last_exit="$(launchctl print "gui/$UID_VALUE/$WRAPPER_LABEL" | awk -F'= ' '/last exit code =/ {print $2; exit}')"
fi
[[ -n "$wrapper_pid" ]] || wrapper_pid="-"
[[ -n "$wrapper_last_exit" ]] || wrapper_last_exit="-"

ninja_pid="$(ps -axww -o pid=,ppid=,command= | awk -v ppid="${wrapper_pid:-0}" '
  $2 == ppid && /ninja/ && /out\/libfuzzer-trend/ && /indexed_db_leveldb_coding_sequence/ {
    print $1
    exit
  }
' || true)"
progress_line=""
if [[ -n "$ninja_pid" ]]; then
  progress_line="$(tail -n 200 "$LOG_FILE" 2>/dev/null | grep -E '^\[[0-9]+/[0-9]+\]' | tail -n 1 || true)"
fi

current_step="-"
total_steps="-"
percent="-"
last_target="-"

if [[ -n "$progress_line" ]]; then
  current_step="$(printf '%s\n' "$progress_line" | sed -E 's/^\[([0-9]+)\/([0-9]+)\].*/\1/')"
  total_steps="$(printf '%s\n' "$progress_line" | sed -E 's/^\[([0-9]+)\/([0-9]+)\].*/\2/')"
  if [[ "$current_step" =~ ^[0-9]+$ && "$total_steps" =~ ^[0-9]+$ && "$total_steps" != "0" ]]; then
    percent="$("$PYTHON_BIN" - <<'PY' "$current_step" "$total_steps"
import sys
current = int(sys.argv[1])
total = int(sys.argv[2])
print(f"{(current / total) * 100:.1f}%")
PY
)"
  fi
  last_target="$(printf '%s\n' "$progress_line" | sed -E 's/^\[[0-9]+\/[0-9]+\] //')"
fi

binary_state="missing"
if [[ -x "$STATEFUL_BINARY" ]]; then
  binary_state="ready"
fi

cat > "$NOTE_FILE" <<EOF
# Build Progress

- state: $wrapper_state
- wrapper_label: $WRAPPER_LABEL
- wrapper_pid: $wrapper_pid
- last_exit_code: $wrapper_last_exit
- ninja_pid: ${ninja_pid:-"-"}
- current_step: $current_step
- total_steps: $total_steps
- progress: $percent
- last_target: $last_target
- binary_state: $binary_state
- binary: $STATEFUL_BINARY
- load_1m: $(load_1m)
- swap_free_mb: $(swap_free_mb)
- checked_at: $(date '+%Y-%m-%d %H:%M:%S %Z')
EOF
