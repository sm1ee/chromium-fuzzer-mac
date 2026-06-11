#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

BINARY=""
COMPONENT=""
TARGET=""
SANITIZER=""
PLATFORM="desktop"
ARTIFACT_ROOT="_artifacts/fuzz"
LANE_REGISTRY="${CHROMIUM_FUZZ_LANE_REGISTRY:-}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --component) COMPONENT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --sanitizer) SANITIZER="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --artifact-root) ARTIFACT_ROOT="$2"; shift 2 ;;
    --lane-registry) LANE_REGISTRY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

EXTRA_ARGS=("$@")

if [[ -z "$BINARY" || -z "$COMPONENT" || -z "$TARGET" || -z "$SANITIZER" ]]; then
  echo "usage: run_fuzztest_target.sh --binary <path> --component <name> --target <name> --sanitizer <name> [--platform <name>] [--artifact-root <dir>] [--dry-run] [-- target-specific args]" >&2
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
LOG_FILE="$SESSION_DIR/logs/run.log"
CMD_FILE="$SESSION_DIR/notes/command.txt"
EXIT_FILE="$SESSION_DIR/notes/exit_code.txt"

if [[ -z "$LANE_REGISTRY" ]]; then
  CANDIDATE_LANE_REGISTRY="$(dirname "$ARTIFACT_ROOT")/lane_registry.json"
  if [[ -f "$CANDIDATE_LANE_REGISTRY" ]]; then
    LANE_REGISTRY="$CANDIDATE_LANE_REGISTRY"
  fi
fi

CMD=("$BINARY")
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  CMD+=("${EXTRA_ARGS[@]}")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "session_dir=$SESSION_DIR"
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

printf '%q ' "${CMD[@]}" > "$CMD_FILE"
printf '\n' >> "$CMD_FILE"

if [[ -n "$LANE_REGISTRY" && -f "$LANE_REGISTRY" ]]; then
  python3 "$SELF_DIR/build_lane_packet.py" \
    --lane-registry "$LANE_REGISTRY" \
    --target "$TARGET" \
    --component "$COMPONENT" \
    --engine fuzztest \
    --sanitizer "$SANITIZER" \
    --platform "$PLATFORM" \
    --artifact-root "$ARTIFACT_ROOT" \
    --binary "$BINARY" \
    --session-dir "$SESSION_DIR" \
    --out-json "$SESSION_DIR/notes/lane_packet.json" \
    --out-md "$SESSION_DIR/notes/lane_packet.md" >/dev/null
fi

set +e
"${CMD[@]}" 2>&1 | tee "$LOG_FILE"
STATUS=${PIPESTATUS[0]}
set -e
printf '%s\n' "$STATUS" > "$EXIT_FILE"
echo "session_dir=$SESSION_DIR"
echo "exit_code=$STATUS"
exit "$STATUS"
