#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
INTERVAL_SECS="${INTERVAL_SECS:-3600}"
LOG_DIR="$ROOT/fuzz/logs"
LOG_FILE="$LOG_DIR/fuzz_status_batch.log"

mkdir -p "$LOG_DIR"

if [[ ! "$INTERVAL_SECS" =~ ^[0-9]+$ || "$INTERVAL_SECS" -lt 1 ]]; then
  echo "invalid INTERVAL_SECS=$INTERVAL_SECS" >&2
  exit 2
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

while true; do
  if "$ROOT/fuzz/post_fuzz_status_batch.sh"; then
    log "status post complete"
  else
    log "status post failed"
  fi
  sleep "$INTERVAL_SECS"
done
