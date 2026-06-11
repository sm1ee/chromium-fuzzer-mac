#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

CHECKOUT=""
OUT_DIR=""
TARGET=""
ENGINE=""
COMPONENT=""
SANITIZER=""
PLATFORM="desktop"
ARTIFACT_ROOT="_artifacts/fuzz"
CORPUS_DIR=""
TESTCASE=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkout) CHECKOUT="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --component) COMPONENT="$2"; shift 2 ;;
    --sanitizer) SANITIZER="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --artifact-root) ARTIFACT_ROOT="$2"; shift 2 ;;
    --corpus-dir) CORPUS_DIR="$2"; shift 2 ;;
    --testcase) TESTCASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

EXTRA_ARGS=("$@")

if [[ -z "$CHECKOUT" || -z "$TARGET" || -z "$ENGINE" || -z "$COMPONENT" || -z "$SANITIZER" ]]; then
  echo "usage: run_managed_fuzz.sh --checkout <path> --target <name> --engine <libfuzzer|fuzztest|clusterfuzz-repro> --component <name> --sanitizer <name> [--out-dir <dir>] [--platform <name>] [--artifact-root <dir>] [--corpus-dir <dir>] [--testcase <path>] [--dry-run] [-- extra args]" >&2
  exit 2
fi

RESOLVE_CMD=(python3 "$SELF_DIR/resolve_fuzz_binary.py" --checkout "$CHECKOUT" --target "$TARGET")
if [[ -n "$OUT_DIR" ]]; then
  RESOLVE_CMD+=(--out-dir "$OUT_DIR")
fi
RESOLVE_JSON="$("${RESOLVE_CMD[@]}")"
BINARY="$(python3 - <<'PY' "$RESOLVE_JSON"
import json, sys
data=json.loads(sys.argv[1])
matches=data.get("matches", [])
print(matches[0]["binary"] if matches else "")
PY
)"

if [[ -z "$BINARY" ]]; then
  echo "error: could not resolve binary for target '$TARGET'" >&2
  exit 2
fi

case "$ENGINE" in
  libfuzzer)
    CMD=(bash "$SELF_DIR/run_libfuzzer_target.sh" \
      --binary "$BINARY" \
      --component "$COMPONENT" \
      --target "$TARGET" \
      --sanitizer "$SANITIZER" \
      --platform "$PLATFORM" \
      --artifact-root "$ARTIFACT_ROOT")
    if [[ -n "$CORPUS_DIR" ]]; then CMD+=(--corpus-dir "$CORPUS_DIR"); fi
    if [[ "$DRY_RUN" -eq 1 ]]; then CMD+=(--dry-run); fi
    CMD+=(--)
    if (( ${#EXTRA_ARGS[@]} > 0 )); then CMD+=("${EXTRA_ARGS[@]}"); fi
    exec "${CMD[@]}"
    ;;
  fuzztest)
    CMD=(bash "$SELF_DIR/run_fuzztest_target.sh" \
      --binary "$BINARY" \
      --component "$COMPONENT" \
      --target "$TARGET" \
      --sanitizer "$SANITIZER" \
      --platform "$PLATFORM" \
    --artifact-root "$ARTIFACT_ROOT")
    if [[ "$DRY_RUN" -eq 1 ]]; then CMD+=(--dry-run); fi
    CMD+=(--)
    if (( ${#EXTRA_ARGS[@]} > 0 )); then CMD+=("${EXTRA_ARGS[@]}"); fi
    exec "${CMD[@]}"
    ;;
  clusterfuzz-repro)
    if [[ -z "$TESTCASE" ]]; then
      echo "error: --testcase is required for clusterfuzz-repro" >&2
      exit 2
    fi
    CMD=(bash "$SELF_DIR/run_clusterfuzz_repro.sh" \
      --binary "$BINARY" \
      --component "$COMPONENT" \
      --target "$TARGET" \
      --sanitizer "$SANITIZER" \
      --platform "$PLATFORM" \
      --artifact-root "$ARTIFACT_ROOT" \
      --testcase "$TESTCASE")
    if [[ "$DRY_RUN" -eq 1 ]]; then CMD+=(--dry-run); fi
    CMD+=(--)
    if (( ${#EXTRA_ARGS[@]} > 0 )); then CMD+=("${EXTRA_ARGS[@]}"); fi
    exec "${CMD[@]}"
    ;;
  *)
    echo "error: unknown engine '$ENGINE'" >&2
    exit 2
    ;;
esac
