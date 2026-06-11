#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

CHECKOUT=""
COMPONENT=""
ENGINE=""
SANITIZER=""
PLATFORM="desktop"
TARGET=""
OUT_DIR=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkout) CHECKOUT="$2"; shift 2 ;;
    --component) COMPONENT="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --sanitizer) SANITIZER="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$CHECKOUT" || -z "$COMPONENT" || -z "$ENGINE" || -z "$SANITIZER" ]]; then
  echo "usage: run_build_variant.sh --checkout <path> --component <name> --engine <libfuzzer|fuzztest|clusterfuzz-repro> --sanitizer <asan|hwasan|msan|tsan|ubsan> [--platform <name>] [--target <name>] [--out-dir <dir>] [--dry-run]" >&2
  exit 2
fi

PLAN_CMD=(python3 "$SELF_DIR/build_variant_plan.py" --component "$COMPONENT" --engine "$ENGINE" --sanitizer "$SANITIZER" --platform "$PLATFORM")
if [[ -n "$TARGET" ]]; then
  PLAN_CMD+=(--target "$TARGET")
fi
PLAN_JSON="$("${PLAN_CMD[@]}")"
if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$(python3 - <<'PY' "$PLAN_JSON"
import json, sys
print(json.loads(sys.argv[1])["out_dir"])
PY
)"
fi
TARGET_NAME="$(python3 - <<'PY' "$PLAN_JSON"
import json, sys
print(json.loads(sys.argv[1])["target"])
PY
)"
GN_ARGS="$(python3 - <<'PY' "$PLAN_JSON"
import json, sys
print(" ".join(json.loads(sys.argv[1])["gn_args"]))
PY
)"

GN_CMD=(gn gen "$OUT_DIR" "--args=${GN_ARGS}")
BUILD_CMD=(autoninja -C "$OUT_DIR" "$TARGET_NAME")

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%q ' "${GN_CMD[@]}"
  printf '\n'
  printf '%q ' "${BUILD_CMD[@]}"
  printf '\n'
  exit 0
fi

(
  cd "$CHECKOUT"
  "${GN_CMD[@]}"
  "${BUILD_CMD[@]}"
)
