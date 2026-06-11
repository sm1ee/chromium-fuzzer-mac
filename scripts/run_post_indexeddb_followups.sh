#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
UID_VALUE="$(id -u)"
STATEFUL_LABEL="com.bugclaw.chromium-fuzz-indexeddb-stateful"
V8_LABEL="com.bugclaw.chromium-fuzz-v8-semantic"
GRAPHICS_LABEL="com.bugclaw.chromium-fuzz-graphics-precision"
NOTE_FILE="$ROOT/fuzz/managed/plans/followups/current/FOLLOWUP_STATUS.md"

mkdir -p "$(dirname "$NOTE_FILE")"

load_1m() {
  uptime | awk -F'load averages: ' '{print $2}' | awk '{gsub(/^ +| +$/,"",$1); print $1}'
}

swap_free_mb() {
  /usr/sbin/sysctl vm.swapusage | awk -F'free = ' '{print $2}' | awk '{gsub("M","",$1); print int($1)}'
}

is_bootstrapped() {
  local label="$1"
  launchctl print "gui/$UID_VALUE/$label" >/dev/null 2>&1
}

maybe_bootstrap() {
  local label="$1"
  local plist="$2"
  if is_bootstrapped "$label"; then
    return 0
  fi
  launchctl bootstrap "gui/$UID_VALUE" "$plist"
  launchctl kickstart -k "gui/$UID_VALUE/$label"
}

load_now="$(load_1m)"
swap_free_now="$(swap_free_mb)"
stateful_state="waiting"
v8_state="waiting"
graphics_state="waiting"
load_floor="${load_now%.*}"
load_floor="${load_floor:-0}"

if is_bootstrapped "$STATEFUL_LABEL"; then
  stateful_state="ready"
fi

if is_bootstrapped "$V8_LABEL"; then
  v8_state="running"
elif [[ "$stateful_state" == "ready" && "$load_floor" -lt 10 && "$swap_free_now" -gt 512 ]]; then
  maybe_bootstrap \
    "$V8_LABEL" \
    "/Users/bugclaw/Library/LaunchAgents/com.bugclaw.chromium-fuzz-v8-semantic.plist"
  v8_state="bootstrapped"
elif [[ "$stateful_state" == "ready" ]]; then
  v8_state="gated"
fi

if is_bootstrapped "$GRAPHICS_LABEL"; then
  graphics_state="running"
elif [[ "$stateful_state" == "ready" && "$load_floor" -lt 12 && "$swap_free_now" -gt 768 ]]; then
  maybe_bootstrap \
    "$GRAPHICS_LABEL" \
    "/Users/bugclaw/Library/LaunchAgents/com.bugclaw.chromium-fuzz-graphics-precision.plist"
  graphics_state="bootstrapped"
elif [[ "$stateful_state" == "ready" ]]; then
  graphics_state="gated"
fi

cat > "$NOTE_FILE" <<EOF
# Followup Status

- indexeddb_stateful: $stateful_state
- v8_semantic: $v8_state
- graphics_precision: $graphics_state
- load_1m: $load_now
- swap_free_mb: $swap_free_now
- v8_gate: stateful_ready && load<10 && swap_free_mb>512
- graphics_gate: stateful_ready && load<12 && swap_free_mb>768
- checked_at: $(date '+%Y-%m-%d %H:%M:%S %Z')
EOF
