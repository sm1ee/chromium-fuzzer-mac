#!/bin/bash
# Frequent, silent-when-healthy supervision with condition-family dedupe.
set -euo pipefail

OPS_ROOT="/Users/smlee/chromium-worker-ops"
# shellcheck source=/dev/null
source "$OPS_ROOT/config/worker.env"

target="$PRIMARY_TARGET"
binary="$OUT_DIR/$target"
state_dir="$DATA_ROOT/state"
lock_dir="$state_dir/watchdog.lockdir"
active_file="$state_dir/watchdog-active"
alerts_file="$state_dir/watchdog-alerts.tsv"
stamp_file="$state_dir/watchdog.last"
low_since_file="$state_dir/watchdog-workers-low-since"
/bin/mkdir -p "$state_dir"
payload="$(/usr/bin/mktemp "$state_dir/watchdog-payload.XXXXXX")"
realert_secs="${WATCHDOG_REALERT_SECS:-21600}"
worker_grace_secs="${WATCHDOG_WORKER_GRACE_SECS:-600}"
log_stale_secs="${WATCHDOG_LOG_STALE_SECS:-900}"
disk_low_gb="${WATCHDOG_DISK_LOW_GB:-20}"
dry_run="${WATCHDOG_DRY_RUN:-0}"

if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
    /bin/rm -f "$payload"
    exit 0
fi
cleanup() {
    /bin/rm -f "$payload"
    /bin/rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT
/usr/bin/touch "$alerts_file"
/bin/chmod 600 "$alerts_file"

now="$(/bin/date +%s)"
uid_value="$(/usr/bin/id -u)"
label="com.bugclaw.chromium-fuzz-media-h264"
loaded=0
if /bin/launchctl print "gui/$uid_value/$label" >/dev/null 2>&1; then
    loaded=1
fi
coordinator="$(/bin/ps -Ao command= | /usr/bin/awk \
    -v prefix="/bin/bash $OPS_ROOT/bin/lane-loop.sh $target" \
    'index($0, prefix) == 1 {count++} END {print count + 0}')"
workers="$(/bin/ps -Ao command= | /usr/bin/awk \
    -v prefix="$binary " 'index($0, prefix) == 1 && $0 !~ /-jobs=4/ {count++} END {print count + 0}')"

"$OPS_ROOT/bin/provenance-status.sh" "$target" >/dev/null
provenance="$DATA_ROOT/metrics/$target.provenance.json"
reason="$(/usr/bin/jq -r '.reason // "missing"' "$provenance" 2>/dev/null || echo missing)"
eligible="$(/usr/bin/jq -r '.current_tree_eligible // 0' "$provenance" 2>/dev/null || echo 0)"
ops_integrity="$(/usr/bin/jq -r '.ops_integrity // 0' "$provenance" 2>/dev/null || echo 0)"

latest_log=""
log_age=-1
artifact_root="$DATA_ROOT/artifacts/$target"
if [ -d "$artifact_root" ]; then
    latest_log="$(/usr/bin/find "$artifact_root" -type f -path '*/logs/*.log' -print0 |
        /usr/bin/xargs -0 /usr/bin/stat -f '%m %N' 2>/dev/null |
        /usr/bin/sort -nr | /usr/bin/head -n 1 | /usr/bin/cut -d ' ' -f 2- || true)"
    if [ -n "$latest_log" ] && [ -f "$latest_log" ]; then
        log_age=$((now - $(/usr/bin/stat -f '%m' "$latest_log")))
    fi
fi

disk_free_kb="$(/bin/df -Pk "$DATA_ROOT" | /usr/bin/awk 'NR==2 {print $4}')"
disk_free_gb=$((disk_free_kb / 1024 / 1024))
codes=()
details=()
if [ "$loaded" -ne 1 ]; then
    codes+=("LAUNCHD_UNLOADED")
    details+=("launchd label is not loaded")
fi
if [ "$coordinator" -lt 1 ]; then
    codes+=("COORDINATOR_MISSING")
    details+=("lane-loop coordinator count=$coordinator")
elif [ "$coordinator" -gt 1 ]; then
    codes+=("COORDINATOR_DUPLICATE")
    details+=("lane-loop coordinator count=$coordinator")
fi
if [ "$eligible" -ne 1 ] || [ "$ops_integrity" -ne 1 ]; then
    codes+=("PROVENANCE_$reason")
    details+=("provenance reason=$reason eligible=$eligible ops_integrity=$ops_integrity")
fi
if [ "$disk_free_gb" -lt "$disk_low_gb" ]; then
    codes+=("DISK_LOW")
    details+=("disk_free=${disk_free_gb}GB threshold=${disk_low_gb}GB")
fi

if [ "$loaded" -eq 1 ] && [ "$workers" -lt 4 ]; then
    if [ ! -s "$low_since_file" ]; then
        if [ "$dry_run" = "1" ]; then
            low_since="$now"
        else
            /usr/bin/printf '%s\n' "$now" > "$low_since_file"
            /bin/chmod 600 "$low_since_file"
            low_since="$now"
        fi
    else
        low_since="$(/usr/bin/head -n 1 "$low_since_file")"
    fi
    if [[ "$low_since" =~ ^[0-9]+$ ]] && [ $((now - low_since)) -ge "$worker_grace_secs" ]; then
        codes+=("WORKERS_LOW")
        details+=("workers=$workers/4 persisted=$((now - low_since))s")
    fi
elif [ "$dry_run" != "1" ]; then
    /bin/rm -f "$low_since_file"
fi
if [ "$workers" -gt 4 ]; then
    codes+=("WORKERS_EXCESS")
    details+=("workers=$workers/4 duplicate children suspected")
fi
if [ "$workers" -gt 0 ] && { [ "$log_age" -lt 0 ] || [ "$log_age" -ge "$log_stale_secs" ]; }; then
    codes+=("LOG_STALE")
    details+=("worker log age=${log_age}s threshold=${log_stale_secs}s")
fi

guard_file="$state_dir/discord-rest-guard.tsv"
if [ -s "$guard_file" ]; then
    IFS=$'\t' read -r guard_until guard_reason _ < "$guard_file" || true
    if [[ "${guard_until:-}" =~ ^[0-9]+$ ]] && [ "$now" -lt "$guard_until" ]; then
        codes+=("DISCORD_GUARD")
        details+=("Discord guard reason=${guard_reason:-unknown} until=$guard_until")
    fi
fi

key="HEALTHY"
if [ "${#codes[@]}" -gt 0 ]; then
    for preferred in LAUNCHD_UNLOADED PROVENANCE DISK_LOW COORDINATOR_MISSING COORDINATOR_DUPLICATE WORKERS_LOW WORKERS_EXCESS LOG_STALE DISCORD_GUARD; do
        for code in "${codes[@]}"; do
            if [[ "$code" == "$preferred"* ]]; then
                key="$code"
                break 2
            fi
        done
    done
fi
previous="HEALTHY"
if [ -s "$active_file" ]; then
    previous="$(/usr/bin/head -n 1 "$active_file")"
fi
/usr/bin/printf '%s healthy=%s key=%s workers=%s coordinator=%s log_age=%s disk_free_gb=%s\n' \
    "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$([ "$key" = "HEALTHY" ] && echo true || echo false)" \
    "$key" "$workers" "$coordinator" "$log_age" "$disk_free_gb" > "$stamp_file"

send_payload() {
    if [ "$dry_run" = "1" ]; then
        /bin/cat "$payload"
        DISCORD_DRY_RUN=1 "$OPS_ROOT/bin/discord-send.sh" "$DISCORD_STATUS_CHANNEL_ID" "$payload"
    else
        "$OPS_ROOT/bin/discord-send.sh" "$DISCORD_STATUS_CHANNEL_ID" "$payload"
    fi
}

if [ "$key" = "HEALTHY" ]; then
    if [ "$previous" != "HEALTHY" ]; then
        content="Chromium M1 Max fuzzer watchdog RECOVERED
host: $(/bin/hostname)
target: $target
recovered_condition: $previous
workers: $workers/4
coordinator: $coordinator
provenance: $reason
log_age_secs: $log_age
disk_free_gb: $disk_free_gb
auto_promote: false"
        /usr/bin/jq -n --arg content "$content" '{content:$content}' > "$payload"
        if send_payload; then
            if [ "$dry_run" != "1" ]; then
                /usr/bin/printf '%s\n' "HEALTHY" > "$active_file"
            fi
        fi
    elif [ "$dry_run" != "1" ]; then
        /usr/bin/printf '%s\n' "HEALTHY" > "$active_file"
    fi
    exit 0
fi

last_alert="$(/usr/bin/awk -F '\t' -v key="$key" '$1==key {value=$2} END {print value+0}' "$alerts_file")"
should_alert=0
if [ "$previous" != "$key" ] || [ "$last_alert" -eq 0 ] || [ $((now - last_alert)) -ge "$realert_secs" ]; then
    should_alert=1
fi
if [ "$dry_run" != "1" ]; then
    /usr/bin/printf '%s\n' "$key" > "$active_file"
fi
if [ "$should_alert" -ne 1 ]; then
    echo "[watchdog] degraded but suppressed key=$key workers=$workers/4"
    exit 0
fi

detail_text="$(IFS=' | '; echo "${details[*]}")"
all_codes="$(IFS=','; echo "${codes[*]}")"
severity="yellow"
case "$key" in
    LAUNCHD_UNLOADED|PROVENANCE_*|DISK_LOW) severity="red" ;;
esac
content="Chromium M1 Max fuzzer watchdog DEGRADED
host: $(/bin/hostname)
target: $target
severity: $severity
condition: $key
codes: $all_codes
detail: $detail_text
workers: $workers/4
coordinator: $coordinator
provenance: $reason
log_age_secs: $log_age
disk_free_gb: $disk_free_gb
auto_recover: false
auto_promote: false"
/usr/bin/jq -n --arg content "$content" '{content:$content}' > "$payload"
if send_payload; then
    if [ "$dry_run" != "1" ]; then
        /usr/bin/awk -F '\t' -v key="$key" '$1!=key' "$alerts_file" > "$alerts_file.tmp.$$"
        /bin/mv -f "$alerts_file.tmp.$$" "$alerts_file"
        /usr/bin/printf '%s\t%s\n' "$key" "$now" >> "$alerts_file"
    fi
fi
