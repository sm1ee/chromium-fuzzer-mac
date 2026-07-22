#!/bin/bash
set -euo pipefail

OPS_ROOT="/Users/smlee/chromium-worker-ops"
# shellcheck source=/dev/null
source "$OPS_ROOT/config/worker.env"

/bin/mkdir -p "$DATA_ROOT/state" "$DATA_ROOT/logs"
lock_dir="$DATA_ROOT/state/discord-status.lockdir"
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
    exit 0
fi
payload="$(/usr/bin/mktemp "$DATA_ROOT/state/discord-status-payload.XXXXXX")"
cleanup() {
    /bin/rm -f "$payload"
    /bin/rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT

"$OPS_ROOT/bin/provenance-status.sh" "$PRIMARY_TARGET" >/dev/null
provenance="$DATA_ROOT/metrics/$PRIMARY_TARGET.provenance.json"
reason="$(/usr/bin/jq -r '.reason' "$provenance")"
eligible="$(/usr/bin/jq -r '.current_tree_eligible' "$provenance")"
support_only="$(/usr/bin/jq -r '.support_only' "$provenance")"
detection_kpi_eligible="$(/usr/bin/jq -r '.detection_kpi_eligible' "$provenance")"
ops_integrity="$(/usr/bin/jq -r '.ops_integrity' "$provenance")"
source_head="$(/usr/bin/jq -r '.source_head' "$provenance")"
ops_head="$(/usr/bin/jq -r '.ops_source_head' "$provenance")"
binary="$OUT_DIR/$PRIMARY_TARGET"
worker_count() {
    /bin/ps -Ao command= | /usr/bin/awk -v prefix="$binary " 'index($0, prefix) == 1 && $0 !~ /-jobs=4/ {count++} END {print count + 0}'
}
worker_total="$(worker_count)"
corpus_count=0
if [ -d "$DATA_ROOT/corpus/$PRIMARY_TARGET" ]; then
    corpus_count="$(/usr/bin/find "$DATA_ROOT/corpus/$PRIMARY_TARGET" -maxdepth 1 -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
fi
latest_session="none"
crash_files=0
artifact_root="$DATA_ROOT/artifacts/$PRIMARY_TARGET"
if [ -d "$artifact_root" ]; then
    latest_session="$(/usr/bin/find "$artifact_root" -mindepth 1 -maxdepth 1 -type d | /usr/bin/sort | /usr/bin/tail -n 1)"
    if [ -n "$latest_session" ] && [ -d "$latest_session/crashes" ]; then
        crash_files="$(/usr/bin/find "$latest_session/crashes" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    fi
fi
uid_value="$(/usr/bin/id -u)"
fuzzer_loaded=0
if /bin/launchctl print "gui/$uid_value/com.bugclaw.chromium-fuzz-media-h264" >/dev/null 2>&1; then
    fuzzer_loaded=1
fi
if [ "$fuzzer_loaded" = "1" ] && [ "$worker_total" -lt 4 ]; then
    for _ in {1..30}; do
        /bin/sleep 1
        worker_total="$(worker_count)"
        if [ "$worker_total" -ge 4 ]; then break; fi
    done
fi

content="Chromium M1 Max fuzzer status
host: $(/bin/hostname)
target: $PRIMARY_TARGET
reason: $reason
current_tree_eligible: $eligible
support_only: $support_only
detection_kpi_eligible: $detection_kpi_eligible
ops_integrity: $ops_integrity
source_head: $source_head
ops_head: $ops_head
launchd_loaded: $fuzzer_loaded
workers: $worker_total/4
corpus_files: $corpus_count
latest_session: ${latest_session#$DATA_ROOT/}
latest_session_crashes: $crash_files
auto_promote: false"
/usr/bin/jq -n --arg content "$content" '{content:$content}' > "$payload"
"$OPS_ROOT/bin/discord-send.sh" "$DISCORD_STATUS_CHANNEL_ID" "$payload"
