#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

BINARY=""
COMPONENT=""
TARGET=""
SANITIZER=""
PLATFORM="desktop"
ARTIFACT_ROOT="_artifacts/fuzz"
TESTCASE=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --component) COMPONENT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --sanitizer) SANITIZER="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --artifact-root) ARTIFACT_ROOT="$2"; shift 2 ;;
    --testcase) TESTCASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

EXTRA_ARGS=("$@")

if [[ -z "$BINARY" || -z "$COMPONENT" || -z "$TARGET" || -z "$SANITIZER" || -z "$TESTCASE" ]]; then
  echo "usage: run_clusterfuzz_repro.sh --binary <path> --component <name> --target <name> --sanitizer <name> --testcase <path> [--platform <name>] [--artifact-root <dir>] [--dry-run] [-- extra args]" >&2
  exit 2
fi

INIT_CMD=(python3 "$SELF_DIR/init_fuzz_session.py" --component "$COMPONENT" --target "$TARGET" --sanitizer "$SANITIZER" --platform "$PLATFORM" --root "$ARTIFACT_ROOT")
if [[ "$DRY_RUN" -eq 1 ]]; then
  INIT_CMD+=(--dry-run)
fi
MANIFEST_JSON="$("${INIT_CMD[@]}")"
SESSION_DIR="$(python3 - <<'PY' "$MANIFEST_JSON"
import json, sys
print(json.loads(sys.argv[1])["session_dir"])
PY
)"
LOG_FILE="$SESSION_DIR/logs/repro.log"
CMD_FILE="$SESSION_DIR/notes/command.txt"
EXIT_FILE="$SESSION_DIR/notes/exit_code.txt"

CMD=("$BINARY" "$TESTCASE")
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  CMD+=("${EXTRA_ARGS[@]}")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "session_dir=$SESSION_DIR"
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

cp "$TESTCASE" "$SESSION_DIR/repro/" 2>/dev/null || true
printf '%q ' "${CMD[@]}" > "$CMD_FILE"
printf '\n' >> "$CMD_FILE"

set +e
"${CMD[@]}" 2>&1 | tee "$LOG_FILE"
STATUS=${PIPESTATUS[0]}
set -e
printf '%s\n' "$STATUS" > "$EXIT_FILE"
echo "session_dir=$SESSION_DIR"
echo "exit_code=$STATUS"
exit "$STATUS"
