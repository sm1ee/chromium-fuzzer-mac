#!/bin/bash
# Route strict media/H.264 public issue records into M1 admission packets.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${MEDIA_SEED_STATE_DIR:-$HOME/.cache/chromium-fuzzer-mac-seeds}"
QUEUE_ROOT="${ISSUE_QUEUE_ROOT:-$HOME/.chromium-corpus-variant-queue}"
SYNC_SCRIPT="${ISSUE_SYNC_SCRIPT:-$HOME/bugbounty-skills/skills/browser/chromium-issue-corpus/scripts/sync_from_master_box.sh}"
SYNC_FIRST="${ISSUE_SYNC_FIRST:-0}"
MIRROR_LOCK_DIR="${ISSUE_MIRROR_LOCK_DIR:-/tmp/chromium-issue-corpus-local-sync.lockdir}"
MAX_PER_RUN="${MEDIA_ISSUE_SEED_MAX_PER_RUN:-2}"
MAX_RETRY="${MEDIA_SEED_MAX_RETRY:-3}"
LOOKBACK_DAYS="${MEDIA_ISSUE_SEED_LOOKBACK_DAYS:-7}"
MAX_QUEUE_AGE_DAYS="${MEDIA_ISSUE_SEED_MAX_QUEUE_AGE_DAYS:-1}"

/bin/mkdir -p "$STATE_DIR/outbox"
SEEN="$STATE_DIR/seen.tsv"
FAILURES="$STATE_DIR/failures.tsv"
MANIFEST="$(/usr/bin/mktemp "$STATE_DIR/issue-manifest.XXXXXX")"
trap '/bin/rm -f "$MANIFEST"' EXIT
/usr/bin/touch "$SEEN" "$FAILURES"

if [ "$SYNC_FIRST" = "1" ]; then
    if [ ! -x "$SYNC_SCRIPT" ]; then
        echo "[media-seed] sync script missing/not executable: $SYNC_SCRIPT" >&2
        exit 1
    fi
    if ! "$SYNC_SCRIPT"; then
        echo "[media-seed] sync failed; refusing stale local mirror" >&2
        exit 1
    fi
fi
if [ -d "$MIRROR_LOCK_DIR" ]; then
    echo "[media-seed] mirror sync still active; refusing mixed snapshot"
    exit 0
fi
if [ ! -d "$QUEUE_ROOT" ]; then
    echo "[media-seed] queue root missing: $QUEUE_ROOT"
    exit 0
fi

/usr/bin/python3 -I -S "$REPO_ROOT/tools/media_seed_router.py" issues \
    --queue-root "$QUEUE_ROOT" \
    --outbox "$STATE_DIR/outbox" \
    --manifest "$MANIFEST" \
    --seen "$SEEN" \
    --failures "$FAILURES" \
    --max-per-run "$MAX_PER_RUN" \
    --max-retry "$MAX_RETRY" \
    --lookback-days "$LOOKBACK_DAYS" \
    --max-queue-age-days "$MAX_QUEUE_AGE_DAYS"
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
