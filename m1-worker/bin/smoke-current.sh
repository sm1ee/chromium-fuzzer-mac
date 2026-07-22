#!/bin/bash
set -euo pipefail

OPS_ROOT="/Users/smlee/chromium-worker-ops"
# shellcheck source=/dev/null
source "$OPS_ROOT/config/worker.env"

target="${1:-$PRIMARY_TARGET}"
"$OPS_ROOT/bin/run-lane.sh" "$target" 60 1

provenance_file="$DATA_ROOT/metrics/$target.provenance.json"
run_file="$DATA_ROOT/metrics/$target.latest-run.json"
if ! /usr/bin/jq -e '.current_tree_eligible == 1' "$provenance_file" >/dev/null; then
    echo "smoke failed: provenance is not current-tree eligible" >&2
    exit 10
fi
if ! /usr/bin/jq -e '.exit_code == 0 and .crash_files == 0 and .asan_markers == 0' "$run_file" >/dev/null; then
    echo "smoke failed: non-clean runtime result" >&2
    exit 11
fi

stamp="$DATA_ROOT/state/$target.smoke-ok.json"
temp="$stamp.tmp.$$"
/usr/bin/jq -n \
    --arg generated_at "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg target "$target" \
    --arg source_head "$(/usr/bin/jq -r '.source_head' "$provenance_file")" \
    --arg binary_fingerprint "$(/usr/bin/jq -r '.binary_fingerprint' "$provenance_file")" \
    --arg ops_source_head "$(/usr/bin/jq -r '.ops_source_head' "$provenance_file")" \
    '{generated_at:$generated_at,target:$target,passed:true,source_head:$source_head,binary_fingerprint:$binary_fingerprint,ops_source_head:$ops_source_head}' > "$temp"
/bin/chmod 600 "$temp"
/bin/mv -f "$temp" "$stamp"
echo "smoke_passed target=$target stamp=$stamp"
