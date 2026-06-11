#!/usr/bin/env bash
set -euo pipefail

UID_VALUE="$(id -u)"
V8_LABEL="com.bugclaw.chromium-fuzz-v8-semantic"
GRAPHICS_LABEL="com.bugclaw.chromium-fuzz-graphics-precision"
V8_PLIST="/Users/bugclaw/Library/LaunchAgents/com.bugclaw.chromium-fuzz-v8-semantic.plist"
GRAPHICS_PLIST="/Users/bugclaw/Library/LaunchAgents/com.bugclaw.chromium-fuzz-graphics-precision.plist"

reboot_job() {
  local label="$1"
  local plist="$2"
  launchctl bootout "gui/$UID_VALUE/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID_VALUE" "$plist"
  launchctl kickstart -k "gui/$UID_VALUE/$label"
}

reboot_job "$V8_LABEL" "$V8_PLIST"
reboot_job "$GRAPHICS_LABEL" "$GRAPHICS_PLIST"
