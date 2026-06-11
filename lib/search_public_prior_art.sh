#!/usr/bin/env bash
set -euo pipefail

QUERY=""
LIMIT="5"
API_URL="${TOOL_API_URL:-http://127.0.0.1:8100}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query) QUERY="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  echo "usage: search_public_prior_art.sh --query <text> [--limit <n>]" >&2
  exit 2
fi

echo "# chromium_public"
if ! curl -sS "${API_URL}/tools/search_bugbounty?project=chromium_public&query=$(python3 - <<'PY' "$QUERY"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
)&limit=${LIMIT}"; then
  echo "warning: chromium_public search unavailable at ${API_URL}" >&2
fi

echo
echo "# chromium_public_talks"
if ! curl -sS "${API_URL}/tools/search_bugbounty?project=chromium_public_talks&query=$(python3 - <<'PY' "$QUERY"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
)&limit=${LIMIT}"; then
  echo "warning: chromium_public_talks search unavailable at ${API_URL}" >&2
fi
