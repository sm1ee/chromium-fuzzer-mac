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
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

EXTRA_ARGS=("$@")

if [[ -z "$CHECKOUT" || -z "$COMPONENT" || -z "$ENGINE" || -z "$SANITIZER" ]]; then
  echo "usage: run_fuzz_campaign.sh --checkout <path> --component <name> --engine <libfuzzer|fuzztest|clusterfuzz-repro> --sanitizer <name> [--target <name>] [--platform <name>] [--out-dir <dir>] [--artifact-root <dir>] [--corpus-dir <dir>] [--testcase <path>] [--dry-run] [-- extra args]" >&2
  exit 2
fi

VARIANT_CMD=(python3 "$SELF_DIR/build_variant_plan.py" --component "$COMPONENT" --engine "$ENGINE" --sanitizer "$SANITIZER" --platform "$PLATFORM")
if [[ -n "$TARGET" ]]; then
  VARIANT_CMD+=(--target "$TARGET")
fi
VARIANT_PLAN="$("${VARIANT_CMD[@]}")"
SEED_PACKET="$(python3 "$SELF_DIR/build_seed_bootstrap.py" --component "$COMPONENT" --limit 5)"
TARGET_NAME="$(python3 - <<'PY' "$VARIANT_PLAN"
import json, sys
print(json.loads(sys.argv[1])["target"])
PY
)"

echo "# variant_plan"
echo "$VARIANT_PLAN"
echo
echo "# seed_bootstrap"
echo "$SEED_PACKET"
echo

RUN_CMD=(bash "$SELF_DIR/run_managed_fuzz.sh" --checkout "$CHECKOUT" --target "$TARGET_NAME" --engine "$ENGINE" --component "$COMPONENT" --sanitizer "$SANITIZER" --platform "$PLATFORM" --artifact-root "$ARTIFACT_ROOT")
if [[ -n "$OUT_DIR" ]]; then RUN_CMD+=(--out-dir "$OUT_DIR"); fi
if [[ -n "$CORPUS_DIR" ]]; then RUN_CMD+=(--corpus-dir "$CORPUS_DIR"); fi
if [[ -n "$TESTCASE" ]]; then RUN_CMD+=(--testcase "$TESTCASE"); fi
if [[ "$DRY_RUN" -eq 1 ]]; then RUN_CMD+=(--dry-run); fi
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  RUN_CMD+=(-- "${EXTRA_ARGS[@]}")
fi

echo "# managed_run"
printf '%q ' "${RUN_CMD[@]}"
printf '\n'

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

"${RUN_CMD[@]}"
