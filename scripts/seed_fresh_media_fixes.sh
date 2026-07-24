#!/bin/bash
# Poll current Chromium media paths and route fresh H.264 fixes to the M1.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${MEDIA_SEED_STATE_DIR:-$HOME/.cache/chromium-fuzzer-mac-seeds}"
FETCH_N="${MEDIA_FIX_SEED_FETCH_N:-500}"
MAX_PER_RUN="${MEDIA_FIX_SEED_MAX_PER_RUN:-2}"
MAX_RETRY="${MEDIA_SEED_MAX_RETRY:-3}"
DRY_RUN="${MEDIA_SEED_DRY_RUN:-0}"

/bin/mkdir -p "$STATE_DIR/outbox"
SEEN="$STATE_DIR/seen.tsv"
FAILURES="$STATE_DIR/failures.tsv"
TMP_DIR="$(/usr/bin/mktemp -d "$STATE_DIR/fix-fetch.XXXXXX")"
trap '/bin/rm -rf "$TMP_DIR"' EXIT
COMMITS="$TMP_DIR/commits.jsonl"
MANIFEST="$TMP_DIR/manifest.tsv"
/usr/bin/touch "$SEEN" "$FAILURES" "$COMMITS"

if [ -n "${MEDIA_FIX_SEED_FIXTURE_JSONL:-}" ]; then
    /bin/cp "$MEDIA_FIX_SEED_FIXTURE_JSONL" "$COMMITS"
else
    fetch_ok=0
    url="https://chromium.googlesource.com/chromium/src/+log?n=$FETCH_N&format=JSON"
    raw="$TMP_DIR/chromium-src.raw"
    if ! /usr/bin/curl -fsS --max-time 30 "$url" -o "$raw"; then
        echo "[media-seed] fresh-fix fetch failed repo=chromium/src" >&2
    else
        fetch_ok=1
        /usr/bin/python3 -I -S - "$raw" >> "$COMMITS" <<'PY'
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
if raw.startswith(")]}'"):
    raw = raw.split("\n", 1)[1]
payload = json.loads(raw)
for item in payload.get("log", []):
    commit = str(item.get("commit") or "")
    message = str(item.get("message") or "")
    subject = message.splitlines()[0].strip() if message else ""
    if not commit or not subject:
        continue
    record = {
        "commit": commit,
        "subject": subject,
        "message": message,
        "paths": "",
        "component": "Chromium Media H264 candidate",
        "url": f"https://chromium.googlesource.com/chromium/src/+/{commit}",
    }
    print(json.dumps(record, ensure_ascii=False))
PY
    fi
    if [ "$fetch_ok" -ne 1 ]; then
        exit 1
    fi
fi

if [ ! -s "$COMMITS" ]; then
    echo "[media-seed] no fresh media commits fetched"
    exit 0
fi

/usr/bin/python3 -I -S "$REPO_ROOT/tools/media_seed_router.py" commits \
    --input "$COMMITS" \
    --outbox "$STATE_DIR/outbox" \
    --manifest "$MANIFEST" \
    --seen "$SEEN" \
    --failures "$FAILURES" \
    --max-per-run "$MAX_PER_RUN" \
    --max-retry "$MAX_RETRY"
router_rc=$?
if [ "$router_rc" -ne 0 ]; then
    exit "$router_rc"
fi

record_failure() {
    packet_id="$1"
    old="$(/usr/bin/awk -F '\t' -v p="$packet_id" '$1==p {n=$2} END {print n+0}' "$FAILURES")"
    /usr/bin/awk -F '\t' -v p="$packet_id" '$1!=p' "$FAILURES" > "$FAILURES.tmp.$$"
    /bin/mv -f "$FAILURES.tmp.$$" "$FAILURES"
    /usr/bin/printf '%s\t%s\t%s\n' "$packet_id" "$((old + 1))" "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$FAILURES"
}

while IFS=$'\t' read -r packet packet_id kind source_id title; do
    [ -n "${packet_id:-}" ] || continue
    if "$REPO_ROOT/scripts/send_media_seed_packet.sh" "$packet"; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$packet_id" "$kind" "$source_id" "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$title" >> "$SEEN"
    else
        record_failure "$packet_id"
    fi
done < "$MANIFEST"

if [ "$DRY_RUN" = "1" ]; then
    echo "[media-seed] fresh-fix dry-run complete"
fi
