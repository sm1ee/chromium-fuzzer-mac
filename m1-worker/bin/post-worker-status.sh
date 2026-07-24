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
noise_files=0
asan_markers=0
latest_log="none"
log_age_secs=-1
session_age_secs=-1
exec_per_sec="unknown"
coverage="unknown"
features="unknown"
artifact_root="$DATA_ROOT/artifacts/$PRIMARY_TARGET"
if [ -d "$artifact_root" ]; then
    latest_session="$(/usr/bin/find "$artifact_root" -mindepth 1 -maxdepth 1 -type d | /usr/bin/sort | /usr/bin/tail -n 1)"
    if [ -n "$latest_session" ] && [ -d "$latest_session/crashes" ]; then
        crash_files="$(/usr/bin/find "$latest_session/crashes" -type f \
            \( -name 'crash-*' -o -name 'leak-*' -o -name 'asan-*' -o -name 'ubsan-*' -o -name 'msan-*' -o -name 'tsan-*' \) |
            /usr/bin/wc -l | /usr/bin/tr -d ' ')"
        noise_files="$(/usr/bin/find "$latest_session/crashes" -type f \
            \( -name 'timeout-*' -o -name 'slow-unit-*' -o -name 'oom-*' \) |
            /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    fi
    if [ -n "$latest_session" ] && [ -d "$latest_session/logs" ]; then
        session_age_secs="$(( $(/bin/date +%s) - $(/usr/bin/stat -f '%m' "$latest_session") ))"
        log_files=("$latest_session"/logs/*.log)
        if [ -e "${log_files[0]}" ]; then
            latest_log="$(/usr/bin/find "$latest_session/logs" -type f -name '*.log' -print0 |
                /usr/bin/xargs -0 /usr/bin/stat -f '%m %N' 2>/dev/null |
                /usr/bin/sort -nr | /usr/bin/head -n 1 | /usr/bin/cut -d ' ' -f 2- || true)"
            if [ -n "$latest_log" ] && [ -f "$latest_log" ]; then
                log_age_secs="$(( $(/bin/date +%s) - $(/usr/bin/stat -f '%m' "$latest_log") ))"
            fi
            asan_markers="$(/usr/bin/awk \
                '/ERROR: AddressSanitizer|SUMMARY: AddressSanitizer/ {count++} END {print count + 0}' \
                "${log_files[@]}" 2>/dev/null)"
            progress="$(/usr/bin/grep -hE 'cov: [0-9]+.*ft: [0-9]+.*exec/s: [0-9]+' \
                "${log_files[@]}" 2>/dev/null | /usr/bin/tail -n 1 || true)"
            if [ -n "$progress" ]; then
                exec_per_sec="$(/usr/bin/printf '%s\n' "$progress" |
                    /usr/bin/sed -E 's/.*exec\/s: ([0-9]+).*/\1/')"
                coverage="$(/usr/bin/printf '%s\n' "$progress" |
                    /usr/bin/sed -E 's/.*cov: ([0-9]+).*/\1/')"
                features="$(/usr/bin/printf '%s\n' "$progress" |
                    /usr/bin/sed -E 's/.*ft: ([0-9]+).*/\1/')"
            fi
        fi
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
disk_free_kb="$(/bin/df -Pk "$DATA_ROOT" | /usr/bin/awk 'NR==2 {print $4}')"
disk_free_gb="$((disk_free_kb / 1024 / 1024))"
seed_inbox=0
if [ -d "$DATA_ROOT/seed-inbox" ]; then
    seed_inbox="$(/usr/bin/find "$DATA_ROOT/seed-inbox" -maxdepth 1 -type f -name '*.json' |
        /usr/bin/wc -l | /usr/bin/tr -d ' ')"
fi
seed_admissions=0
if [ -f "$DATA_ROOT/state/seed-admission.tsv" ]; then
    seed_admissions="$(/usr/bin/awk -F '\t' 'length($2)==64 && $2 ~ /^[0-9a-f]+$/ {count++} END {print count + 0}' \
        "$DATA_ROOT/state/seed-admission.tsv")"
fi

content="Chromium M1 Max fuzzer 6h digest
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
session_age_secs: $session_age_secs
log_age_secs: $log_age_secs
exec_per_sec: $exec_per_sec
coverage: $coverage
features: $features
crash_like_artifacts: $crash_files
noise_artifacts_timeout_slow_oom: $noise_files
asan_markers: $asan_markers
disk_free_gb: $disk_free_gb
seed_inbox_pending: $seed_inbox
seed_packets_processed: $seed_admissions
auto_promote: false"
/usr/bin/jq -n --arg content "$content" '{content:$content}' > "$payload"
if [ "${STATUS_DRY_RUN:-0}" = "1" ]; then
    /bin/cat "$payload"
    DISCORD_DRY_RUN=1 "$OPS_ROOT/bin/discord-send.sh" "$DISCORD_STATUS_CHANNEL_ID" "$payload"
else
    "$OPS_ROOT/bin/discord-send.sh" "$DISCORD_STATUS_CHANNEL_ID" "$payload"
fi
