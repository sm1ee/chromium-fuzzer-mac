#!/usr/bin/env bash
set -euo pipefail

BINARY=""
INPUT=""
OUTPUT=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) BINARY="$2"; shift 2 ;;
    --input) INPUT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

EXTRA_ARGS=("$@")

if [[ -z "$BINARY" || -z "$INPUT" || -z "$OUTPUT" ]]; then
  echo "usage: minimize_libfuzzer_crash.sh --binary <path> --input <crash> --output <minimized> [--dry-run] [-- extra args]" >&2
  exit 2
fi
if [[ ! -f "$INPUT" ]]; then
  echo "error: input crash does not exist: $INPUT" >&2
  exit 2
fi

CMD=("$BINARY" "-minimize_crash=1" "-exact_artifact_path=$OUTPUT" "$INPUT")
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  CMD+=("${EXTRA_ARGS[@]}")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

mkdir -p "$(dirname "$OUTPUT")"
"${CMD[@]}"
