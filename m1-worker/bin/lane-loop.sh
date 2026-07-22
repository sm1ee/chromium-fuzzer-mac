#!/bin/bash
set -u

OPS_ROOT="/Users/smlee/chromium-worker-ops"
# shellcheck source=/dev/null
source "$OPS_ROOT/config/worker.env"

target="${1:-$PRIMARY_TARGET}"
session_secs="${SESSION_SECS:-21600}"
workers="${WORKERS:-4}"

while :; do
    if ! /usr/bin/pmset -g batt | /usr/bin/grep -q "AC Power"; then
        /usr/bin/printf '%s status=paused_on_battery target=%s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$target"
        /bin/sleep 300
        continue
    fi
    "$OPS_ROOT/bin/run-lane.sh" "$target" "$session_secs" "$workers"
    rc=$?
    /usr/bin/printf '%s target=%s exit=%s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$target" "$rc"
    if [ "$rc" -eq 0 ]; then
        /bin/sleep 30
    else
        /bin/sleep 300
    fi
done
