#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
MAX_TOTAL_TIME="${MAX_TOTAL_TIME:-172800}"
UID_VALUE="$(id -u)"

# Rotate logs before anything else to prevent disk fill
"$ROOT/fuzz/rotate_logs.sh" || true

"$ROOT/fuzz/ensure_batch_loops.sh" || echo "[recover] ensure_batch_loops failed, continuing" >&2

bootstrap_if_missing() {
  local label="$1"
  local plist_path="$2"

  if [[ ! -f "$plist_path" ]]; then
    echo "missing launchagent plist for $label: $plist_path"
    return 1
  fi

  if launchctl print "gui/$UID_VALUE/$label" >/dev/null 2>&1; then
    echo "launchagent already loaded: $label"
    return 0
  fi

  launchctl enable "gui/$UID_VALUE/$label" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID_VALUE/$label" >/dev/null 2>&1 || true

  if ! launchctl bootstrap "gui/$UID_VALUE" "$plist_path"; then
    echo "bootstrap failed for $label: $plist_path"
    return 1
  fi

  if ! launchctl kickstart -k "gui/$UID_VALUE/$label"; then
    echo "kickstart failed for $label"
    return 1
  fi

  echo "bootstrapped launchagent: $label"
}

bootstrap_if_missing \
  "com.bugclaw.chromium-fuzz-audio-processing-managed" \
  "$ROOT/fuzz/launchagents/com.bugclaw.chromium-fuzz-audio-processing-managed.plist" || true

bootstrap_if_missing \
  "com.bugclaw.chromium-fuzz-indexeddb-managed" \
  "$ROOT/fuzz/launchagents/com.bugclaw.chromium-fuzz-indexeddb-managed.plist" || true

bootstrap_if_missing \
  "com.bugclaw.chromium-fuzz-angle-translator-managed" \
  "$ROOT/fuzz/launchagents/com.bugclaw.chromium-fuzz-angle-translator-managed.plist" || true

bootstrap_if_missing \
  "com.bugclaw.chromium-fuzz-angle-texture-vk-pitch-narrow" \
  "$ROOT/fuzz/launchagents/com.bugclaw.chromium-fuzz-angle-texture-vk-pitch-narrow.plist" || true

bootstrap_if_missing \
  "com.bugclaw.chromium-fuzz-webcodecs-managed" \
  "$ROOT/fuzz/launchagents/com.bugclaw.chromium-fuzz-webcodecs-managed.plist" || true
