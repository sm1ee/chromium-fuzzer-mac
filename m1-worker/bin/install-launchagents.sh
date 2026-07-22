#!/bin/bash
set -euo pipefail

REPO_ROOT="/Users/smlee/chromium-fuzzer-mac"
PROFILE_ROOT="$REPO_ROOT/m1-worker"
# shellcheck source=/dev/null
source "$PROFILE_ROOT/config/worker.env"

load=0
if [ "${1:-}" = "--load" ]; then
    load=1
    shift
fi
if [ "$#" -ne 0 ]; then
    echo "usage: $0 [--load]" >&2
    exit 64
fi

"$PROFILE_ROOT/bin/sync-repo.sh" --no-fetch
repo_head="$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)"
deployed_head="$(/usr/bin/tr -d '\r\n' < "$OPS_ROOT/deploy-head.txt" 2>/dev/null || true)"
if [ "$repo_head" != "$deployed_head" ]; then
    echo "operations deploy is not current; retry after active worker/build locks clear" >&2
    exit 75
fi
/bin/mkdir -p "/Users/smlee/Library/LaunchAgents" "$DATA_ROOT/logs"
for plist in "$PROFILE_ROOT"/launchagents/*.plist; do
    /usr/bin/plutil -lint "$plist" >/dev/null
    /bin/cp "$plist" "/Users/smlee/Library/LaunchAgents/$(/usr/bin/basename "$plist")"
    /bin/chmod 644 "/Users/smlee/Library/LaunchAgents/$(/usr/bin/basename "$plist")"
done

if [ "$load" != "1" ]; then
    echo "launchagents installed but not loaded; run smoke-current.sh, then rerun with --load"
    exit 0
fi

target="webcodecs_video_decoder_fuzzer"
provenance_file="$DATA_ROOT/metrics/$target.provenance.json"
smoke_file="$DATA_ROOT/state/$target.smoke-ok.json"
"$OPS_ROOT/bin/provenance-status.sh" "$target" >/dev/null
if ! /usr/bin/jq -e '.current_tree_eligible == 1' "$provenance_file" >/dev/null; then
    echo "refusing launch: current-tree provenance gate failed" >&2
    exit 10
fi
if ! /usr/bin/jq -e '.passed == true' "$smoke_file" >/dev/null 2>&1; then
    echo "refusing launch: successful smoke stamp is missing" >&2
    exit 11
fi
for field in source_head binary_fingerprint ops_source_head; do
    current="$(/usr/bin/jq -r ".$field" "$provenance_file")"
    smoked="$(/usr/bin/jq -r ".$field" "$smoke_file")"
    if [ "$current" != "$smoked" ]; then
        echo "refusing launch: smoke stamp mismatch field=$field" >&2
        exit 12
    fi
done

uid_value="$(/usr/bin/id -u)"
labels=(
    com.bugclaw.chromium-worker-sync
    com.bugclaw.chromium-worker-health
    com.bugclaw.chromium-fuzz-webcodecs
)
for label in "${labels[@]}"; do
    plist="/Users/smlee/Library/LaunchAgents/$label.plist"
    /bin/launchctl bootout "gui/$uid_value/$label" >/dev/null 2>&1 || true
    /bin/launchctl bootstrap "gui/$uid_value" "$plist"
done
echo "launchagents loaded labels=${labels[*]}"
