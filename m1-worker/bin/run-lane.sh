#!/bin/bash
set -euo pipefail

OPS_ROOT="/Users/smlee/chromium-worker-ops"
# shellcheck source=/dev/null
source "$OPS_ROOT/config/worker.env"

target="${1:-webcodecs_video_decoder_fuzzer}"
max_total_time="${2:-21600}"
workers="${3:-4}"
binary="$OUT_DIR/$target"
corpus_dir="$DATA_ROOT/corpus/$target"
artifact_base="$DATA_ROOT/artifacts/$target"
lock_dir="$DATA_ROOT/state/$target.lockdir"
provenance_file="$DATA_ROOT/metrics/$target.provenance.json"

if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
    echo "lane already active target=$target" >&2
    exit 75
fi
cleanup() { /bin/rmdir "$lock_dir" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

"$OPS_ROOT/bin/provenance-status.sh" "$target" >/dev/null
if ! /usr/bin/jq -e '.current_tree_eligible == 1' "$provenance_file" >/dev/null; then
    reason="$(/usr/bin/jq -r '.reason' "$provenance_file")"
    echo "refusing non-current lane target=$target reason=$reason support_only=1 detection_kpi_eligible=0" >&2
    exit 78
fi

timestamp="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
session_dir="$artifact_base/$timestamp"
/bin/mkdir -p "$corpus_dir" "$session_dir/crashes" "$session_dir/logs" "$session_dir/notes"
/bin/cp "$provenance_file" "$session_dir/manifest.json"

fuzz_args=(
    "$corpus_dir"
    "-artifact_prefix=$session_dir/crashes/"
    "-max_total_time=$max_total_time"
    -timeout=30
    -rss_limit_mb=4096
    "-jobs=$workers"
    "-workers=$workers"
    -print_final_stats=1
)
if [ -f "$OPS_ROOT/dicts/$target.dict" ]; then
    fuzz_args+=("-dict=$OPS_ROOT/dicts/$target.dict")
fi

command_file="$session_dir/notes/command.txt"
/usr/bin/printf '%q ' "$binary" "${fuzz_args[@]}" > "$command_file"
/usr/bin/printf '\n' >> "$command_file"

symbolizer="$SRC_ROOT/third_party/llvm-build/Release+Asserts/bin/llvm-symbolizer"
export ASAN_SYMBOLIZER_PATH="$symbolizer"
export ASAN_OPTIONS="abort_on_error=1:allocator_may_return_null=1:detect_leaks=0:symbolize=1"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1"

set +e
/usr/bin/caffeinate -dimsu "$binary" "${fuzz_args[@]}" 2>&1 | /usr/bin/tee "$session_dir/logs/run.log"
rc=${PIPESTATUS[0]}
set -e

/usr/bin/printf '%s\n' "$rc" > "$session_dir/notes/exit_code.txt"
crash_count="$(/usr/bin/find "$session_dir/crashes" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
asan_markers="$(/usr/bin/grep -Ec '(^|[[:space:]])(ERROR: AddressSanitizer|SUMMARY: AddressSanitizer)' "$session_dir/logs/run.log" 2>/dev/null || true)"
metrics_file="$DATA_ROOT/metrics/$target.latest-run.json"
temp_file="$metrics_file.tmp.$$"
/usr/bin/jq -n \
    --arg generated_at "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg target "$target" \
    --arg session_dir "$session_dir" \
    --argjson exit_code "$rc" \
    --argjson crash_files "$crash_count" \
    --argjson asan_markers "$asan_markers" \
    '{generated_at:$generated_at,target:$target,session_dir:$session_dir,exit_code:$exit_code,crash_files:$crash_files,asan_markers:$asan_markers,auto_promote:false}' > "$temp_file"
/bin/mv -f "$temp_file" "$metrics_file"
exit "$rc"
