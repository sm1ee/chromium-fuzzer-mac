#!/bin/bash
# Install the M4 control-plane media seed routers; load only with --load.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/LaunchAgents"
load=0
if [ "${1:-}" = "--load" ]; then
    load=1
    shift
fi
if [ "$#" -ne 0 ]; then
    echo "usage: install-media-seed-launchagents.sh [--load]" >&2
    exit 64
fi

/bin/mkdir -p "$DEST" "$HOME/.cache/chromium-fuzzer-mac-seeds"
for plist in "$REPO_ROOT"/launchagents/com.bugclaw.chromium-fuzzer-mac-seed-*.plist; do
    /usr/bin/plutil -lint "$plist" >/dev/null
    destination="$DEST/$(/usr/bin/basename "$plist")"
    /bin/cp "$plist" "$destination"
    /bin/chmod 644 "$destination"
done

if [ "$load" -ne 1 ]; then
    echo "control-plane LaunchAgents installed but not loaded"
    exit 0
fi

uid_value="$(/usr/bin/id -u)"
for label in \
    com.bugclaw.chromium-fuzzer-mac-seed-issue-corpus \
    com.bugclaw.chromium-fuzzer-mac-seed-fresh; do
    plist="$DEST/$label.plist"
    /bin/launchctl bootout "gui/$uid_value/$label" >/dev/null 2>&1 || true
    /bin/launchctl bootstrap "gui/$uid_value" "$plist"
done
echo "control-plane media seed LaunchAgents loaded"
