#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"
shopt -s nullglob

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
ARTIFACT_ROOT="$ROOT/fuzz/logs/artifacts"
MANAGED_ARTIFACT_ROOT="$ROOT/fuzz/managed/artifacts"
EXTRA_ARTIFACT_ROOT="${EXTRA_ARTIFACT_ROOT:-$MANAGED_ARTIFACT_ROOT}"
LEGACY_EXTRA_ARTIFACT_ROOT="${LEGACY_EXTRA_ARTIFACT_ROOT:-/tmp/chromium-vrp-fuzz/artifacts}"
REGISTRY_QUERY_PY="$ROOT/fuzz/managed/registry_query.py"
PYTHON_BIN="${PYTHON_BIN:-/Users/bugclaw/.openclaw/workspace/depot_tools/bootstrap-2@3.11.8.chromium.35_bin/python3/bin/python3}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="/opt/homebrew/bin/python3"
fi
STATE_DIR="$ROOT/fuzz/state"
SECRETS_DIR="$ROOT/.secrets"
TOKEN_FILE="$SECRETS_DIR/discord_bug_claw_bot_token"
CRASH_CHANNEL_ID="1491693222022615142"
AUX_CHANNEL_ID="1491816591132721323"
STATE_FILE="$STATE_DIR/notified_artifact_fingerprints.txt"
ARTIFACT_FIND_MAXDEPTH="${ARTIFACT_FIND_MAXDEPTH:-6}"
ARTIFACT_LOOKBACK_MINUTES="${ARTIFACT_LOOKBACK_MINUTES:-360}"
REGISTERED_SESSION_LOOKBACK_COUNT="${REGISTERED_SESSION_LOOKBACK_COUNT:-5}"
NOTIFY_REGISTERED_INACTIVE_DIRS="${NOTIFY_REGISTERED_INACTIVE_DIRS:-0}"
DISCORD_CURL_TIMEOUT="${DISCORD_CURL_TIMEOUT:-20}"
FRESH_BINARY_MAX_AGE_SECS="${FRESH_BINARY_MAX_AGE_SECS:-604800}"
NOTIFY_SUPPORT_ONLY_CRASHES="${NOTIFY_SUPPORT_ONLY_CRASHES:-0}"
TMP_LIST="$(mktemp)"
TMP_NEW="$(mktemp)"
TMP_RESPONSE="$(mktemp)"
trap 'rm -f "$TMP_LIST" "$TMP_NEW" "$TMP_RESPONSE"' EXIT
EXTRA_WATCH_FILES=(
  "$ROOT/fuzz/managed/plans/indexeddb_stateful_sequence/current/BUILD_PROGRESS.md"
  "$ROOT/fuzz/managed/plans/indexeddb_stateful_sequence/current/PROMOTION_STATUS.md"
  "$ROOT/fuzz/managed/plans/followups/current/FOLLOWUP_STATUS.md"
)

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

# Prune state file if too large (keep last 50000 entries ≈ 30 days)
STATE_MAX_LINES="${STATE_MAX_LINES:-50000}"
state_lines="$(wc -l < "$STATE_FILE" | tr -d ' ')"
if (( state_lines > STATE_MAX_LINES )); then
  tail -n "$STATE_MAX_LINES" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

if [[ ! -s "$TOKEN_FILE" ]]; then
  echo "missing token file: $TOKEN_FILE" >&2
  exit 1
fi

TOKEN="$(head -n 1 "$TOKEN_FILE" | tr -d '\r\n')"

ARTIFACT_ROOTS=("$ARTIFACT_ROOT")
if [[ -d "$EXTRA_ARTIFACT_ROOT" ]]; then
  ARTIFACT_ROOTS+=("$EXTRA_ARTIFACT_ROOT")
fi
if [[ -d "$LEGACY_EXTRA_ARTIFACT_ROOT" && "$LEGACY_EXTRA_ARTIFACT_ROOT" != "$EXTRA_ARTIFACT_ROOT" ]]; then
  ARTIFACT_ROOTS+=("$LEGACY_EXTRA_ARTIFACT_ROOT")
fi

infer_artifact_meta() {
  local abs_path="$1"
  local rel_path=""
  local fuzzer=""
  local rel=""
  local component=""
  local target=""

  if [[ "$abs_path" == "$ARTIFACT_ROOT/"* ]]; then
    rel="${abs_path#$ARTIFACT_ROOT/}"
    fuzzer="${rel%%/*}"
    rel_path="${abs_path#/Users/bugclaw/.openclaw/workspace/}"
  elif [[ "$abs_path" == "$EXTRA_ARTIFACT_ROOT/"* || "$abs_path" == "$LEGACY_EXTRA_ARTIFACT_ROOT/"* ]]; then
    if [[ "$abs_path" == "$EXTRA_ARTIFACT_ROOT/"* ]]; then
      rel="${abs_path#$EXTRA_ARTIFACT_ROOT/}"
    else
      rel="${abs_path#$LEGACY_EXTRA_ARTIFACT_ROOT/}"
    fi
    IFS='/' read -r component target _ <<<"$rel"
    fuzzer="${target:-$component}"
    if [[ "$abs_path" == /Users/bugclaw/.openclaw/workspace/* ]]; then
      rel_path="${abs_path#/Users/bugclaw/.openclaw/workspace/}"
    else
      rel_path="${abs_path#/}"
    fi
  else
    rel_path="$abs_path"
    fuzzer="$(basename "$(dirname "$abs_path")")"
  fi

  printf '%s\t%s\n' "$fuzzer" "$rel_path"
}

artifact_support_only_reason() {
  local abs_path="$1"
  "$PYTHON_BIN" -S - "$abs_path" "$FRESH_BINARY_MAX_AGE_SECS" <<'PY'
import json
import pathlib
import shlex
import sys
import time

path = pathlib.Path(sys.argv[1])
fresh_max = int(sys.argv[2])

def session_dir_for_artifact(p: pathlib.Path):
    if p.parent.name == "crashes":
        return p.parent.parent
    return None

def binary_for_session(session: pathlib.Path):
    packet = session / "notes" / "lane_packet.json"
    if packet.is_file():
        try:
            data = json.loads(packet.read_text(encoding="utf-8", errors="replace"))
            binary = data.get("runtime", {}).get("binary", "")
            if binary:
                return pathlib.Path(binary)
        except Exception:
            pass
    cmd = session / "notes" / "command.txt"
    if cmd.is_file():
        try:
            parts = shlex.split(cmd.read_text(encoding="utf-8", errors="replace"))
            if parts:
                return pathlib.Path(parts[0])
        except Exception:
            pass
    return None

session = session_dir_for_artifact(path)
if session is None:
    raise SystemExit(1)
binary = binary_for_session(session)
if binary is None:
    print("no_binary_metadata")
    raise SystemExit(0)
if not binary.exists():
    print("binary_missing")
    raise SystemExit(0)
age = max(0, int(time.time() - binary.stat().st_mtime))
if age > fresh_max:
    print(f"old_binary_age_days={age / 86400:.1f}")
    raise SystemExit(0)
raise SystemExit(1)
PY
}

channel_for_artifact() {
  local abs_path="$1"
  local support_only="$2"
  if [[ "$support_only" == "1" ]]; then
    printf '%s\n' "$AUX_CHANNEL_ID"
    return 0
  fi
  if [[ "$abs_path" == */crashes/* ]]; then
    printf '%s\n' "$CRASH_CHANNEL_ID"
  else
    printf '%s\n' "$AUX_CHANNEL_ID"
  fi
}

should_notify_artifact() {
  local abs_path="$1"
  local filename
  filename="$(basename "$abs_path")"

  if [[ "$abs_path" != */crashes/* ]]; then
    return 0
  fi

  case "$filename" in
    crash-*|leak-*|asan-*|ubsan-*|msan-*|tsan-*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

active_crash_dirs_for_root() {
  local root="$1"
  ps -axww -o command= 2>/dev/null | "$PYTHON_BIN" -c '
import re
import sys

root = sys.argv[1].rstrip("/") + "/"
seen = set()
for line in sys.stdin:
    for match in re.finditer(r"-artifact_prefix=([^ ]+/crashes/)", line):
        path = match.group(1)
        if path.startswith(root) and path not in seen:
            seen.add(path)
            print(path)
' "$root"
}

registered_crash_dirs_for_root() {
  local root="$1"
  local target=""
  local artifact_dir=""

  artifact_mtime() {
    local path="$1"
    stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path" 2>/dev/null || echo 0
  }

  recent_sessions_for_artifact_dir() {
    local dir="$1"
    local session=""
    [[ -d "$dir" ]] || return 0
    if [[ -d "$dir/crashes" ]]; then
      printf '%s\n' "$dir"
    fi
    find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
      sort |
      tail -n "$REGISTERED_SESSION_LOOKBACK_COUNT"
  }

  [[ -f "$REGISTRY_QUERY_PY" ]] || return 0
  while IFS= read -r target; do
    while IFS= read -r artifact_dir; do
      [[ "$artifact_dir" == "$root/"* ]] || continue
      [[ -d "$artifact_dir" ]] || continue
      while IFS= read -r session_dir; do
        [[ -d "$session_dir/crashes" ]] || continue
        if find "$session_dir/crashes" -maxdepth 1 -type f -mmin "-$ARTIFACT_LOOKBACK_MINUTES" -print -quit 2>/dev/null | grep -q .; then
          printf '%s\n' "$session_dir/crashes"
        fi
      done < <(recent_sessions_for_artifact_dir "$artifact_dir")
    done < <("$PYTHON_BIN" -S "$REGISTRY_QUERY_PY" artifact-dirs "$target" 2>/dev/null)
  done < <("$PYTHON_BIN" -S "$REGISTRY_QUERY_PY" managed-targets 2>/dev/null)
}

collect_artifact_candidates() {
  local root="$1"
  if [[ "$root" == "$MANAGED_ARTIFACT_ROOT" || "$root" == "$EXTRA_ARTIFACT_ROOT" || "$root" == "$LEGACY_EXTRA_ARTIFACT_ROOT" ]]; then
    local crash_dir
    while IFS= read -r crash_dir; do
      [[ -d "$crash_dir" ]] || continue
      find "$crash_dir" -maxdepth 1 -type f -mmin "-$ARTIFACT_LOOKBACK_MINUTES"
    done < <(active_crash_dirs_for_root "$root")
    if [[ "$NOTIFY_REGISTERED_INACTIVE_DIRS" == "1" ]]; then
      while IFS= read -r crash_dir; do
        find "$crash_dir" -maxdepth 1 -type f -mmin "-$ARTIFACT_LOOKBACK_MINUTES"
      done < <(registered_crash_dirs_for_root "$root")
    fi
    return
  fi

  find "$root" -maxdepth "$ARTIFACT_FIND_MAXDEPTH" -type f -mmin "-$ARTIFACT_LOOKBACK_MINUTES"
}

: >"$TMP_LIST"
for root in "${ARTIFACT_ROOTS[@]}"; do
  if [[ -d "$root" ]]; then
    collect_artifact_candidates "$root" >>"$TMP_LIST"
  fi
done
for file in "${EXTRA_WATCH_FILES[@]}"; do
  if [[ -f "$file" ]]; then
    printf '%s\n' "$file" >>"$TMP_LIST"
  fi
done
sort -o "$TMP_LIST" "$TMP_LIST"

: >"$TMP_NEW"
while IFS= read -r abs_path; do
  meta="$(infer_artifact_meta "$abs_path")"
  fuzzer="${meta%%$'\t'*}"
  rel_path="${meta#*$'\t'}"
  sha256="$(shasum -a 256 "$abs_path" | awk '{print $1}')"
  fingerprint="${fuzzer}:${sha256}:${rel_path}"
  if ! grep -Fqx "$fingerprint" "$STATE_FILE"; then
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$fingerprint" "$sha256" "$abs_path" "$fuzzer" "$rel_path" >>"$TMP_NEW"
  fi
done <"$TMP_LIST"

if [[ ! -s "$TMP_NEW" ]]; then
  exit 0
fi

while IFS=$'\t' read -r fingerprint sha256 abs_path fuzzer rel_path; do
  if ! should_notify_artifact "$abs_path"; then
    printf '%s\n' "$fingerprint" >>"$STATE_FILE"
    continue
  fi

  support_only=0
  support_only_reason=""
  if [[ "$abs_path" == */crashes/* ]]; then
    if support_only_reason="$(artifact_support_only_reason "$abs_path")"; then
      support_only=1
      if [[ "$NOTIFY_SUPPORT_ONLY_CRASHES" != "1" ]]; then
        echo "skip support-only crash artifact: $rel_path reason=$support_only_reason" >&2
        printf '%s\n' "$fingerprint" >>"$STATE_FILE"
        continue
      fi
    fi
  fi

  filename="$(basename "$abs_path")"
  size_bytes="$(wc -c <"$abs_path" | tr -d ' ')"
  channel_id="$(channel_for_artifact "$abs_path" "$support_only")"

  PAYLOAD="$(
    "$PYTHON_BIN" - "$abs_path" "$fuzzer" "$filename" "$size_bytes" "$rel_path" "$sha256" "$channel_id" "$support_only" "$support_only_reason" <<'PY'
import json
import pathlib
import sys
from datetime import datetime

path = pathlib.Path(sys.argv[1])
fuzzer = sys.argv[2]
filename = sys.argv[3]
size_bytes = sys.argv[4]
rel_path = sys.argv[5]
sha256 = sys.argv[6]
channel_id = sys.argv[7]
support_only = sys.argv[8]
support_only_reason = sys.argv[9]
raw = path.read_bytes()
sample = raw[:384]

def make_preview(blob: bytes) -> str:
    try:
        text = blob.decode("utf-8")
    except UnicodeDecodeError:
        text = None
    if text is not None:
        printable = sum(ch.isprintable() or ch in "\r\n\t" for ch in text)
        if text and "\x00" not in text and printable / max(1, len(text)) >= 0.85:
            cleaned = text.replace("\r", "").strip()
            if len(cleaned) > 600:
                cleaned = cleaned[:600] + "\n...[truncated]"
            return cleaned or "[empty text preview]"
    hex_preview = " ".join(f"{b:02x}" for b in sample[:64])
    if len(raw) > 64:
        hex_preview += " ..."
    return "[hex preview]\n" + hex_preview

content = (
    f"Chromium fuzz artifact detected on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n"
    f"channel: {channel_id}\n"
    f"fuzzer: {fuzzer}\n"
    f"file: {filename}\n"
    f"size: {size_bytes} bytes\n"
    f"sha256: {sha256}\n"
    f"support_only: {support_only}\n"
    f"support_only_reason: {support_only_reason or '-'}\n"
    f"path: {rel_path}\n\n"
    f"preview:\n{make_preview(raw)}"
)

print(json.dumps({"content": content}, ensure_ascii=False))
PY
)"

  sent=0
  for attempt in 1 2; do
    : >"$TMP_RESPONSE"
    status="$(curl -sS --max-time "$DISCORD_CURL_TIMEOUT" -o "$TMP_RESPONSE" -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bot $TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary "$PAYLOAD" \
      "https://discord.com/api/v10/channels/$channel_id/messages" || echo curl_failed)"
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
      echo "discord send failed: channel=$channel_id status=$status response=$(head -c 300 "$TMP_RESPONSE" | tr '\n\r' '  ')" >&2
      break
    fi
  done

  if (( sent == 0 )); then
    echo "[warn] discord send failed after retries, status=$status" >&2
    continue
  fi

  printf '%s\n' "$fingerprint" >>"$STATE_FILE"
done <"$TMP_NEW"
