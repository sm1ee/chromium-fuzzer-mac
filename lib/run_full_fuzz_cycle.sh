#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

CHECKOUT=""
COMPONENT=""
TARGET=""
ENGINE=""
SANITIZER=""
PLATFORM="desktop"
OUT_DIR=""
ARTIFACT_ROOT="_artifacts/fuzz"
CORPUS_DIR=""
TESTCASE=""
BUILD=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkout) CHECKOUT="$2"; shift 2 ;;
    --component) COMPONENT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --sanitizer) SANITIZER="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --artifact-root) ARTIFACT_ROOT="$2"; shift 2 ;;
    --corpus-dir) CORPUS_DIR="$2"; shift 2 ;;
    --testcase) TESTCASE="$2"; shift 2 ;;
    --build) BUILD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

EXTRA_ARGS=("$@")

if [[ -z "$CHECKOUT" || -z "$COMPONENT" || -z "$ENGINE" || -z "$SANITIZER" ]]; then
  echo "usage: run_full_fuzz_cycle.sh --checkout <path> --component <name> --engine <libfuzzer|fuzztest|clusterfuzz-repro> --sanitizer <name> [--target <name>] [--platform <name>] [--out-dir <dir>] [--artifact-root <dir>] [--corpus-dir <dir>] [--testcase <path>] [--build] [--dry-run] [-- extra args]" >&2
  exit 2
fi

VARIANT_CMD=(python3 "$SELF_DIR/build_variant_plan.py" --component "$COMPONENT" --engine "$ENGINE" --sanitizer "$SANITIZER" --platform "$PLATFORM")
if [[ -n "$TARGET" ]]; then
  VARIANT_CMD+=(--target "$TARGET")
fi
VARIANT_JSON="$("${VARIANT_CMD[@]}")"
TARGET_NAME="$(python3 - <<'PY' "$VARIANT_JSON"
import json, sys
print(json.loads(sys.argv[1])["target"])
PY
)"

if [[ "$BUILD" -eq 1 ]]; then
  BUILD_CMD=(bash "$SELF_DIR/run_build_variant.sh" --checkout "$CHECKOUT" --component "$COMPONENT" --engine "$ENGINE" --sanitizer "$SANITIZER" --platform "$PLATFORM" --target "$TARGET_NAME")
  if [[ -n "$OUT_DIR" ]]; then BUILD_CMD+=(--out-dir "$OUT_DIR"); fi
  if [[ "$DRY_RUN" -eq 1 ]]; then BUILD_CMD+=(--dry-run); fi
  echo "# build_step"
  printf '%q ' "${BUILD_CMD[@]}"
  printf '\n'
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "${BUILD_CMD[@]}"
  fi
  echo
fi

RUN_CMD=(bash "$SELF_DIR/run_fuzz_campaign.sh" --checkout "$CHECKOUT" --component "$COMPONENT" --engine "$ENGINE" --sanitizer "$SANITIZER" --platform "$PLATFORM" --artifact-root "$ARTIFACT_ROOT")
if [[ -n "$TARGET" ]]; then RUN_CMD+=(--target "$TARGET"); fi
if [[ -n "$OUT_DIR" ]]; then RUN_CMD+=(--out-dir "$OUT_DIR"); fi
if [[ -n "$CORPUS_DIR" ]]; then RUN_CMD+=(--corpus-dir "$CORPUS_DIR"); fi
if [[ -n "$TESTCASE" ]]; then RUN_CMD+=(--testcase "$TESTCASE"); fi
if [[ "$DRY_RUN" -eq 1 ]]; then RUN_CMD+=(--dry-run); fi
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  RUN_CMD+=(-- "${EXTRA_ARGS[@]}")
fi

echo "# campaign_step"
printf '%q ' "${RUN_CMD[@]}"
printf '\n'

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "# summary_step"
  echo "python3 $SELF_DIR/summarize_fuzz_session.py --session-dir <latest-session-dir>"
  echo "# handoff_step"
  echo "python3 $SELF_DIR/build_exploitability_handoff.py --session-dir <latest-session-dir> --signature '<summary>' --process-boundary unknown"
  exit 0
fi

"${RUN_CMD[@]}"

LATEST_SESSION="$(python3 - <<'PY' "$ARTIFACT_ROOT" "$COMPONENT" "$TARGET_NAME"
from pathlib import Path
import sys
root = Path(sys.argv[1]) / sys.argv[2] / sys.argv[3]
sessions = sorted([p for p in root.iterdir() if p.is_dir()]) if root.exists() else []
print(sessions[-1] if sessions else "")
PY
)"

if [[ -n "$LATEST_SESSION" ]]; then
  echo
  echo "# summary"
  python3 "$SELF_DIR/summarize_fuzz_session.py" --session-dir "$LATEST_SESSION"
  echo
  echo "# handoff"
  python3 "$SELF_DIR/build_exploitability_handoff.py" --session-dir "$LATEST_SESSION" --process-boundary unknown
fi
