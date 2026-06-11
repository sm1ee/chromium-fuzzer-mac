#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
STATE_DIR="$ROOT/fuzz/state"
LOG_DIR="$ROOT/fuzz/logs"
STATUS_PID_FILE="$STATE_DIR/run_fuzz_status_batch.pid"
ARTIFACT_PID_FILE="$STATE_DIR/run_artifact_notifier_batch.pid"

mkdir -p "$STATE_DIR" "$LOG_DIR"

ensure_loop() {
  local name="$1"
  local pid_file="$2"
  local interval="$3"
  local script="$4"
  local out_log="$5"
  local lock_dir="${pid_file}.lock"
  local old_pid old_cmd existing_pid

  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "another ensure_loop is checking $name"
    return 0
  fi

  if [[ -f "$pid_file" ]]; then
    old_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      old_cmd="$(ps -p "$old_pid" -o command= 2>/dev/null || true)"
      if [[ "$old_cmd" == *"$script"* ]]; then
        rmdir "$lock_dir"
        return 0
      fi
      echo "stale pid file for $name points at unrelated pid=$old_pid"
    fi
  fi

  existing_pid="$(
    ps -axo pid=,command= |
      awk -v script="$script" '
        index($0, script) > 0 && $0 !~ /awk / {
          print $1
          found = 1
          exit
        }
        END { exit(found ? 0 : 1) }
      ' 2>/dev/null || true
  )"
  existing_pid="${existing_pid//[[:space:]]/}"
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "$existing_pid" >"$pid_file"
    echo "relinked $name pid=$existing_pid"
    rmdir "$lock_dir"
    return 0
  fi

  nohup env INTERVAL_SECS="$interval" "$script" >>"$out_log" 2>&1 &
  echo $! >"$pid_file"
  echo "started $name pid=$(cat "$pid_file")"
  rmdir "$lock_dir"
}

ensure_loop \
  "status_batch" \
  "$STATUS_PID_FILE" \
  "3600" \
  "$ROOT/fuzz/run_fuzz_status_batch.sh" \
  "$LOG_DIR/run_fuzz_status_batch.out"

ensure_loop \
  "artifact_notifier_batch" \
  "$ARTIFACT_PID_FILE" \
  "300" \
  "$ROOT/fuzz/run_artifact_notifier_batch.sh" \
  "$LOG_DIR/run_artifact_notifier_batch.out"
