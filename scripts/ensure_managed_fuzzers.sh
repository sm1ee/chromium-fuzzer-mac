#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
SRC_ROOT="$ROOT/src"
WRAPPER_ROOT="/Users/bugclaw/bugbounty-skills/skills/browser/chromium-fuzzing-lab/scripts"
REGISTRY_QUERY_PY="$ROOT/fuzz/managed/registry_query.py"
PYTHON_BIN="${PYTHON_BIN:-/Users/bugclaw/.openclaw/workspace/depot_tools/bootstrap-2@3.11.8.chromium.35_bin/python3/bin/python3}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="/opt/homebrew/bin/python3"
fi
MANAGED_ROOT="$ROOT/fuzz/managed"
ARTIFACT_ROOT="$MANAGED_ROOT/artifacts"
AI_ROOT="$MANAGED_ROOT/ai"
LAUNCH_LOG_ROOT="$MANAGED_ROOT/launcher-logs"
PID_ROOT="$MANAGED_ROOT/pids"
CORPUS_ROOT="$ROOT/fuzz/corpus"
STATE_DIR="$ROOT/fuzz/state"
MAX_TOTAL_TIME="${MAX_TOTAL_TIME:-172800}"

MANAGED_TARGETS=()
while IFS= read -r target; do
  [[ -n "$target" ]] && MANAGED_TARGETS+=("$target")
done < <("$PYTHON_BIN" -S "$REGISTRY_QUERY_PY" managed-targets)

mkdir -p "$ARTIFACT_ROOT" "$AI_ROOT" "$LAUNCH_LOG_ROOT" "$PID_ROOT" "$CORPUS_ROOT" "$STATE_DIR"

COMPONENT=""
TARGET=""
BINARY=""
SANITIZER=""
CORPUS_NAME=""
CORPUS_DIR=""
PID_FILE=""
LAUNCH_LOG=""
EXTRA_ARGS=()

configure_target() {
  TARGET="$1"
  COMPONENT=""
  BINARY=""
  SANITIZER="asan"
  CORPUS_NAME=""
  CORPUS_DIR=""
  PID_FILE=""
  LAUNCH_LOG=""
  EXTRA_ARGS=()

  local cfg_file
  cfg_file="$(mktemp "${TMPDIR:-/tmp}/managed-fuzzer-config.XXXXXX")"
  if ! "$PYTHON_BIN" -S "$REGISTRY_QUERY_PY" shell-config "$TARGET" >"$cfg_file"; then
    rm -f "$cfg_file"
    return 2
  fi
  # shellcheck source=/dev/null
  source "$cfg_file"
  rm -f "$cfg_file"

  if [[ -z "$TARGET" || -z "$COMPONENT" || -z "$BINARY" || -z "$CORPUS_NAME" ]]; then
    echo "invalid managed fuzzer config for ${1:-<empty>}: target=$TARGET component=$COMPONENT binary=$BINARY corpus=$CORPUS_NAME" >&2
    return 2
  fi

  CORPUS_DIR="$CORPUS_ROOT/$CORPUS_NAME"
  PID_FILE="$PID_ROOT/$TARGET.pid"
  LAUNCH_LOG="$LAUNCH_LOG_ROOT/$TARGET.log"
}

stop_existing() {
  local target="$1"
  local corpus_dir="$2"
  local pid pids=""

  is_managed_root_pid() {
    local candidate="$1"
    local cmd
    cmd="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
    [[ "$cmd" == *"$WRAPPER_ROOT/run_libfuzzer_target.sh"* ]] &&
      [[ "$cmd" == *"--binary $BINARY"* ]] &&
      [[ "$cmd" == *"--target $target"* ]] &&
      [[ "$cmd" == *"--artifact-root $ARTIFACT_ROOT"* ]] &&
      [[ "$cmd" == *"--corpus-dir $corpus_dir"* ]]
  }

  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && is_managed_root_pid "$pid"; then
      pids="$pid"
    fi
  fi

  if [[ -z "${pids// /}" ]]; then
    pids="$(
      ps -axo pid=,command= |
        awk -v wrapper="$WRAPPER_ROOT/run_libfuzzer_target.sh" \
            -v binary="$BINARY" \
            -v corpus="$corpus_dir" \
            -v target="$target" \
            -v artifact_root="$ARTIFACT_ROOT" '
          index($0, wrapper) &&
          index($0, "--binary " binary) &&
          index($0, "--target " target) &&
          index($0, "--artifact-root " artifact_root) &&
          index($0, "--corpus-dir " corpus) {
            print $1
          }
        ' || true
    )"
  fi

  if [[ -z "${pids// /}" ]]; then
    echo "no exact managed root to stop for $target; leaving any manual/replay processes alone"
    return 1
  fi

  _collect_descendants() {
    local root="$1" depth="${2:-0}" children child
    if (( depth > 20 )); then return; fi
    children="$(pgrep -P "$root" 2>/dev/null || true)"
    for child in $children; do
      echo "$child"
      _collect_descendants "$child" $((depth + 1))
    done
  }

  declare -A pid_trees
  for pid in $pids; do
    pid_trees[$pid]="$pid $(_collect_descendants "$pid" 0 | tr '\n' ' ')"
  done
  for pid in $pids; do
    # shellcheck disable=SC2086
    kill ${pid_trees[$pid]} 2>/dev/null || true
  done
  sleep 1
  for pid in $pids; do
    # shellcheck disable=SC2086
    kill -9 ${pid_trees[$pid]} 2>/dev/null || true
  done
}

latest_session_dir_for_target() {
  local target="$1"
  configure_target "$target" >/dev/null
  local base_dir="$ARTIFACT_ROOT/$COMPONENT/$TARGET"
  if [[ ! -d "$base_dir" ]]; then
    return 0
  fi
  find "$base_dir" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1
}

latest_exit_code_for_target() {
  local target="$1"
  local session_dir
  session_dir="$(latest_session_dir_for_target "$target")"
  if [[ -z "$session_dir" || ! -f "$session_dir/notes/exit_code.txt" ]]; then
    return 0
  fi
  tr -d '\r\n' <"$session_dir/notes/exit_code.txt"
}

recent_exit_codes_for_target() {
  local target="$1"
  local limit="${2:-3}"
  configure_target "$target" >/dev/null
  local base_dir="$ARTIFACT_ROOT/$COMPONENT/$TARGET"
  if [[ ! -d "$base_dir" ]]; then
    return 0
  fi

  while IFS= read -r exit_file; do
    [[ -f "$exit_file" ]] || continue
    tr -d '\r\n' <"$exit_file"
    printf '\n'
  done < <(find "$base_dir" -path '*/notes/exit_code.txt' | sort | tail -n "$limit")
}

managed_root_lines_for_target() {
  local target="$1"
  local process_snapshot="${2:-}"

  if [[ -z "$process_snapshot" ]]; then
    process_snapshot="$(ps -axww -o pid=,command= 2>/dev/null || true)"
  fi

  configure_target "$target" >/dev/null

  printf '%s\n' "$process_snapshot" |
    awk -v wrapper="$WRAPPER_ROOT/run_libfuzzer_target.sh" \
        -v binary="$BINARY" \
        -v corpus="$CORPUS_DIR" \
        -v target="$target" \
        -v artifact_root="$ARTIFACT_ROOT" '
      index($0, wrapper) &&
      index($0, "--binary " binary) &&
      index($0, "--target " target) &&
      index($0, "--artifact-root " artifact_root) &&
      index($0, "--corpus-dir " corpus) {
        print
      }
    ' || true
}

target_binary_lines_for_target() {
  local target="$1"
  local process_snapshot="${2:-}"

  if [[ -z "$process_snapshot" ]]; then
    process_snapshot="$(ps -axww -o pid=,command= 2>/dev/null || true)"
  fi

  configure_target "$target" >/dev/null

  printf '%s\n' "$process_snapshot" |
    awk -v binary="$BINARY" 'index($0, binary) { print }' || true
}

is_target_running() {
  local target="$1"
  local process_snapshot="${2:-}"

  if [[ -z "$process_snapshot" ]]; then
    process_snapshot="$(ps -axww -o pid=,command= 2>/dev/null || true)"
  fi

  [[ -n "$(managed_root_lines_for_target "$target" "$process_snapshot")" ]] && return 0
  return 1
}

has_external_target_process() {
  local target="$1"
  local process_snapshot="${2:-}"

  if [[ -z "$process_snapshot" ]]; then
    process_snapshot="$(ps -axww -o pid=,command= 2>/dev/null || true)"
  fi

  [[ -n "$(target_binary_lines_for_target "$target" "$process_snapshot")" ]] &&
    [[ -z "$(managed_root_lines_for_target "$target" "$process_snapshot")" ]]
}

# Check whether the managed wrapper's actual arguments match the expected
# configuration. A bare target binary without the wrapper is treated as an
# external/manual run, not as drift that this script is allowed to restart.
has_config_drift() {
  local target="$1"
  local process_snapshot="${2:-}"

  if [[ -z "$process_snapshot" ]]; then
    process_snapshot="$(ps -axww -o pid=,command= 2>/dev/null || true)"
  fi

  configure_target "$target" >/dev/null

  if ! is_target_running "$target" "$process_snapshot"; then
    return 1
  fi

  local running_cmd
  running_cmd="$(managed_root_lines_for_target "$target" "$process_snapshot" | head -1)"
  if [[ -z "$running_cmd" ]]; then
    echo "live target binary found for $target but no exact managed root; leaving it alone"
    return 1
  fi

  local required
  for required in \
    "$WRAPPER_ROOT/run_libfuzzer_target.sh" \
    "--binary $BINARY" \
    "--component $COMPONENT" \
    "--target $TARGET" \
    "--sanitizer $SANITIZER" \
    "--platform desktop" \
    "--artifact-root $ARTIFACT_ROOT" \
    "--corpus-dir $CORPUS_DIR" \
    "--max-total-time $MAX_TOTAL_TIME" \
    "--lane-registry $MANAGED_ROOT/lane_registry.json"; do
    if [[ "$running_cmd" != *"$required"* ]]; then
      echo "config drift: $target missing required fragment '$required' in running process"
      return 0
    fi
  done

  local arg
  for arg in "${EXTRA_ARGS[@]}"; do
    if [[ "$running_cmd" != *"$arg"* ]]; then
      echo "config drift: $target missing arg '$arg' in running process"
      return 0
    fi
  done

  return 1
}

start_target() {
  local target="$1"
  configure_target "$target"

  mkdir -p "$CORPUS_DIR"

  local snapshot
  local restart_existing=0
  snapshot="$(ps -axww -o pid=,command= 2>/dev/null || true)"

  if is_target_running "$target" "$snapshot"; then
    if has_config_drift "$target" "$snapshot"; then
      echo "config drift detected for $target — restarting with updated args"
      restart_existing=1
    else
      echo "already running $target"
      return 0
    fi
  elif has_external_target_process "$target" "$snapshot"; then
    echo "external/manual target process detected for $target; starting managed wrapper anyway"
  fi

  if [[ ! -x "$BINARY" ]]; then
    echo "skipping $target: missing binary $BINARY" >&2
    return 0
  fi

  if (( restart_existing == 1 )); then
    if ! stop_existing "$target" "$CORPUS_DIR"; then
      echo "skipping restart for $target: no exact managed root found"
      return 0
    fi
  else
    stop_existing "$target" "$CORPUS_DIR" >/dev/null 2>&1 || true
  fi

  local cmd=(
    bash "$WRAPPER_ROOT/run_libfuzzer_target.sh"
    --binary "$BINARY"
    --component "$COMPONENT"
    --target "$TARGET"
    --sanitizer "$SANITIZER"
    --platform desktop
    --artifact-root "$ARTIFACT_ROOT"
    --corpus-dir "$CORPUS_DIR"
    --max-total-time "$MAX_TOTAL_TIME"
    --lane-registry "$MANAGED_ROOT/lane_registry.json"
  )

  if (( ${#EXTRA_ARGS[@]} > 0 )); then
    cmd+=(-- "${EXTRA_ARGS[@]}")
  fi

  nohup "${cmd[@]}" >"$LAUNCH_LOG" 2>&1 &
  echo $! >"$PID_FILE"
}

main() {
  local targets=("$@")
  if (( ${#targets[@]} == 0 )); then
    targets=("${MANAGED_TARGETS[@]}")
  fi

  local target
  for target in "${targets[@]}"; do
    start_target "$target"
  done

  echo "launched managed fuzzers with max_total_time=$MAX_TOTAL_TIME"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
