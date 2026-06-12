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

bootstrap_managed_if_no_legacy() {
  local managed_label="$1"
  local plist_path="$2"
  local legacy_label="$3"

  if launchctl print "gui/$UID_VALUE/$managed_label" >/dev/null 2>&1; then
    echo "launchagent already loaded: $managed_label"
    return 0
  fi

  if [[ "${ALLOW_MAC_FUZZ_DUPLICATE:-0}" != "1" ]] && \
     launchctl print "gui/$UID_VALUE/$legacy_label" >/dev/null 2>&1; then
    echo "skip managed duplicate: $managed_label because legacy $legacy_label is already loaded"
    return 0
  fi

  bootstrap_if_missing "$managed_label" "$plist_path"
}

bootstrap_managed_if_no_legacy \
  "com.bugclaw.chromium-fuzz-audio-processing-managed" \
  "$ROOT/fuzz/launchagents/com.bugclaw.chromium-fuzz-audio-processing-managed.plist" \
  "com.bugclaw.chromium-fuzz-audio-processing" || true

bootstrap_managed_if_no_legacy \
  "com.bugclaw.chromium-fuzz-indexeddb-managed" \
  "$ROOT/fuzz/launchagents/com.bugclaw.chromium-fuzz-indexeddb-managed.plist" \
  "com.bugclaw.chromium-fuzz-indexeddb" || true

bootstrap_managed_if_no_legacy \
  "com.bugclaw.chromium-fuzz-angle-translator-managed" \
  "$ROOT/fuzz/launchagents/com.bugclaw.chromium-fuzz-angle-translator-managed.plist" \
  "com.bugclaw.chromium-fuzz-angle-translator" || true

bootstrap_if_missing \
  "com.bugclaw.chromium-fuzz-angle-texture-vk-pitch-narrow" \
  "$ROOT/fuzz/launchagents/com.bugclaw.chromium-fuzz-angle-texture-vk-pitch-narrow.plist" || true

bootstrap_managed_if_no_legacy \
  "com.bugclaw.chromium-fuzz-webcodecs-managed" \
  "$ROOT/fuzz/launchagents/com.bugclaw.chromium-fuzz-webcodecs-managed.plist" \
  "com.bugclaw.chromium-fuzz-webcodecs" || true
