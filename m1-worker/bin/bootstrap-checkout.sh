#!/bin/bash
set -euo pipefail

OPS_ROOT="/Users/smlee/chromium-worker-ops"
# shellcheck source=/dev/null
source "$OPS_ROOT/config/worker.env"

/bin/mkdir -p "$WORKER_ROOT" "$DATA_ROOT/logs" "$DATA_ROOT/state"

if [ ! -x "$XCODE_APP/Contents/Developer/usr/bin/xcodebuild" ]; then
    echo "full Xcode is missing: $XCODE_APP" >&2
    exit 2
fi
if ! /usr/bin/xcodebuild -version; then
    echo "Xcode validation failed" >&2
    exit 2
fi
if [ ! -x "$DEPOT_TOOLS/fetch" ] || [ ! -x "$DEPOT_TOOLS/gclient" ]; then
    echo "depot_tools is incomplete: $DEPOT_TOOLS" >&2
    exit 2
fi

cd "$WORKER_ROOT"
full_xcode_developer_dir="$DEVELOPER_DIR"
if [ ! -f .gclient ]; then
    if [ -e src ]; then
        echo "refusing bootstrap: src exists but .gclient is missing" >&2
        exit 2
    fi
    export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
    /usr/bin/caffeinate -dimsu "$DEPOT_TOOLS/fetch" --nohooks --no-history chromium
else
    export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
    /usr/bin/caffeinate -dimsu "$DEPOT_TOOLS/gclient" sync -D --nohooks
fi

cd "$SRC_ROOT"
/usr/bin/caffeinate -dimsu "$DEPOT_TOOLS/gclient" sync -D --nohooks

head_value="$(/usr/bin/git rev-parse HEAD)"
dirty_count="$(/usr/bin/git status --porcelain --untracked-files=no | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [ "$dirty_count" != "0" ]; then
    echo "checkout is dirty after sync; refusing to attest" >&2
    exit 3
fi

/usr/bin/printf '%s %s\n' "$head_value" "$(/bin/date +%s)" > "$EXPECTED_HEAD_FILE"
/bin/chmod 600 "$EXPECTED_HEAD_FILE"

export DEVELOPER_DIR="$full_xcode_developer_dir"
if ! /usr/bin/xcodebuild -checkFirstLaunchStatus; then
    echo "checkout_ready_hooks_pending head=$head_value reason=xcode_first_launch_required" >&2
    exit 69
fi
/usr/bin/caffeinate -dimsu "$DEPOT_TOOLS/gclient" runhooks
echo "checkout_ready head=$head_value source=$SRC_ROOT"
