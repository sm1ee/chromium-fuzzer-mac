#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
REGISTRY_QUERY_PY="$ROOT/fuzz/managed/registry_query.py"
PYTHON_BIN="${PYTHON_BIN:-/Users/bugclaw/.openclaw/workspace/depot_tools/bootstrap-2@3.11.8.chromium.35_bin/python3/bin/python3}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="/opt/homebrew/bin/python3"
fi
SECRETS_DIR="$ROOT/.secrets"
TOKEN_FILE="$SECRETS_DIR/discord_bug_claw_bot_token"
STATUS_CHANNEL_ID="1491699514334248980"
DISCORD_CURL_TIMEOUT="${DISCORD_CURL_TIMEOUT:-20}"
STATUS_TIMEOUT_SECS="${STATUS_TIMEOUT_SECS:-60}"
STATUS_FUZZERS_DEFAULT=()
while IFS= read -r fuzzer; do
  [[ -n "$fuzzer" ]] && STATUS_FUZZERS_DEFAULT+=("$fuzzer")
done < <("$PYTHON_BIN" -S "$REGISTRY_QUERY_PY" managed-targets | grep -v '^mojo_core_channel_fuzzer$')
TMP_STATUS="$(mktemp)"
TMP_PAYLOADS="$(mktemp)"
TMP_RESPONSE="$(mktemp)"
trap 'rm -f "$TMP_STATUS" "$TMP_PAYLOADS" "$TMP_RESPONSE"' EXIT

if [[ ! -s "$TOKEN_FILE" ]]; then
  echo "missing token file: $TOKEN_FILE" >&2
  exit 1
fi

TOKEN="$(head -n 1 "$TOKEN_FILE" | tr -d '\r\n')"
if [[ -n "${STATUS_FUZZERS:-}" ]]; then
  # shellcheck disable=SC2206
  set -f; STATUS_FUZZERS_DEFAULT=($STATUS_FUZZERS); set +f
fi

if ! timeout "$STATUS_TIMEOUT_SECS" "$ROOT/fuzz/status_managed_fuzzers.sh" "${STATUS_FUZZERS_DEFAULT[@]}" > "$TMP_STATUS"; then
  echo "status collection failed or timed out after ${STATUS_TIMEOUT_SECS}s" >&2
  exit 1
fi

"$PYTHON_BIN" - "$TMP_STATUS" > "$TMP_PAYLOADS" <<'PY'
import json
import pathlib
import sys

status_path = pathlib.Path(sys.argv[1])
text = status_path.read_text(encoding="utf-8", errors="replace").rstrip() + "\n"
max_len = 1800
lines = text.splitlines()
chunks = []
current = ""

for line in lines:
    candidate = line if not current else current + "\n" + line
    if len(candidate) <= max_len:
        current = candidate
        continue
    if current:
        chunks.append(current)
        current = ""
    while len(line) > max_len:
        chunks.append(line[:max_len])
        line = line[max_len:]
    current = line

if current:
    chunks.append(current)

for idx, chunk in enumerate(chunks, start=1):
    prefix = f"[{idx}/{len(chunks)}]\n" if len(chunks) > 1 else ""
    print(json.dumps({"content": prefix + chunk}, ensure_ascii=False))
PY

while IFS= read -r payload; do
  [[ -n "$payload" ]] || continue
  sent=0
  for attempt in 1 2; do
    : >"$TMP_RESPONSE"
    status="$(curl -sS --max-time "$DISCORD_CURL_TIMEOUT" -o "$TMP_RESPONSE" -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bot $TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary "$payload" \
      "https://discord.com/api/v10/channels/$STATUS_CHANNEL_ID/messages" || echo curl_failed)"
    if [[ "$status" == "429" ]]; then
      retry_after=""
      retry_after="$("$PYTHON_BIN" -c "import json,sys; print(int(float(json.load(open(sys.argv[1])).get('retry_after',5)))+1)" "$TMP_RESPONSE" 2>/dev/null || echo 10)"
      echo "discord rate limited: sleeping ${retry_after}s (attempt $attempt)" >&2
      sleep "$retry_after"
      continue
    elif [[ "$status" == 2* ]]; then
      sent=1
      break
    else
      echo "discord send failed: channel=$STATUS_CHANNEL_ID status=$status response=$(head -c 300 "$TMP_RESPONSE" | tr '\n\r' '  ')" >&2
      break
    fi
  done
  if (( sent == 0 )); then
    echo "[warn] discord send failed after retries, status=$status" >&2
    continue
  fi
done < "$TMP_PAYLOADS"
