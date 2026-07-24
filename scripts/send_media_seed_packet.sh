#!/bin/bash
# Validate and atomically deliver one media/H.264 packet to the M1 inbox.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKET="${1:?usage: send_media_seed_packet.sh <packet.json>}"
MAC_HOST="${MEDIA_SEED_MAC_HOST:-mac.server}"
REMOTE_INBOX="${MEDIA_SEED_REMOTE_INBOX:-/Users/smlee/chromium-fuzz-data/seed-inbox}"
DRY_RUN="${MEDIA_SEED_DRY_RUN:-0}"

if [ ! -f "$PACKET" ]; then
    echo "[media-seed] packet missing: $PACKET" >&2
    exit 2
fi
if [[ ! "$MAC_HOST" =~ ^[A-Za-z0-9._@-]+$ ]] ||
   [[ ! "$REMOTE_INBOX" =~ ^/Users/smlee/[A-Za-z0-9._/-]+$ ]]; then
    echo "[media-seed] unsafe delivery target host=$MAC_HOST inbox=$REMOTE_INBOX" >&2
    exit 2
fi
packet_id="$(/usr/bin/python3 -I -S "$REPO_ROOT/tools/media_seed_router.py" validate "$PACKET")"
remote_name="$packet_id.json"
remote_partial="$REMOTE_INBOX/.$remote_name.partial"
remote_final="$REMOTE_INBOX/$remote_name"

if [ "$DRY_RUN" = "1" ]; then
    echo "[media-seed] dry-run send packet=$packet_id host=$MAC_HOST inbox=$REMOTE_INBOX"
    exit 0
fi

if ! /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=8 "$MAC_HOST" \
    "/bin/mkdir -p '$REMOTE_INBOX' && /bin/chmod 700 '$REMOTE_INBOX'"; then
    echo "[media-seed] M1 inbox unavailable host=$MAC_HOST" >&2
    exit 12
fi
if ! /usr/bin/scp -q "$PACKET" "$MAC_HOST:$remote_partial"; then
    echo "[media-seed] upload failed packet=$packet_id" >&2
    exit 12
fi
if ! /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=8 "$MAC_HOST" \
    "/bin/chmod 600 '$remote_partial' && /bin/mv -f '$remote_partial' '$remote_final'"; then
    /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=8 "$MAC_HOST" \
        "/bin/rm -f '$remote_partial'" >/dev/null 2>&1 || true
    echo "[media-seed] atomic publish failed packet=$packet_id" >&2
    exit 12
fi
echo "[media-seed] sent packet=$packet_id host=$MAC_HOST"
