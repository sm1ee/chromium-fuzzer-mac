#!/bin/bash
# Admit M4-routed seed packets only after deterministic mutation and live ASAN validation.
set -euo pipefail
shopt -s nullglob

OPS_ROOT="/Users/smlee/chromium-worker-ops"
# shellcheck source=/dev/null
source "$OPS_ROOT/config/worker.env"

target="$PRIMARY_TARGET"
binary="$OUT_DIR/$target"
corpus="$DATA_ROOT/corpus/$target"
inbox="$DATA_ROOT/seed-inbox"
processed="$DATA_ROOT/seed-processed"
quarantine="$DATA_ROOT/seed-quarantine"
work_root="$DATA_ROOT/state/seed-admission"
ledger="$DATA_ROOT/state/seed-admission.tsv"
max_per_run="${SEED_ADMISSION_MAX_PER_RUN:-2}"
lock_dir="$DATA_ROOT/state/seed-admission.lockdir"

/bin/mkdir -p "$inbox" "$processed" "$quarantine" "$work_root" "$corpus"
/bin/chmod 700 "$inbox" "$processed" "$quarantine" "$work_root"
/usr/bin/touch "$ledger"
/bin/chmod 600 "$ledger"
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
    exit 0
fi
cleanup() { /bin/rmdir "$lock_dir" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$OPS_ROOT/bin/provenance-status.sh" "$target" >/dev/null
provenance="$DATA_ROOT/metrics/$target.provenance.json"
if ! /usr/bin/jq -e \
    '.current_tree_eligible == 1 and .support_only == 0 and .detection_kpi_eligible == 1 and .ops_integrity == 1' \
    "$provenance" >/dev/null; then
    echo "[seed-admission] current-tree provenance gate failed; inbox preserved" >&2
    exit 78
fi
if [ ! -x "$binary" ]; then
    echo "[seed-admission] binary missing: $binary" >&2
    exit 78
fi

symbolizer="$SRC_ROOT/third_party/llvm-build/Release+Asserts/bin/llvm-symbolizer"
export ASAN_SYMBOLIZER_PATH="$symbolizer"
export ASAN_OPTIONS="abort_on_error=1:allocator_may_return_null=1:detect_leaks=0:symbolize=1"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1"

handled=0
packets=("$inbox"/*.json)
for packet in "${packets[@]}"; do
    if [ "$handled" -ge "$max_per_run" ]; then
        break
    fi
    handled=$((handled + 1))
    if ! packet_id="$(/usr/bin/python3 -I -S "$OPS_ROOT/bin/h264-seed-mutator.py" validate "$packet" 2>&1)"; then
        invalid_name="$(/usr/bin/basename "$packet").invalid.$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
        /bin/mv -f "$packet" "$quarantine/$invalid_name"
        /usr/bin/printf '%s\tinvalid_packet\t%s\t%s\n' \
            "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$invalid_name" "$packet_id" >> "$ledger"
        continue
    fi
    if /usr/bin/awk -F '\t' -v id="$packet_id" '$2==id {found=1} END {exit !found}' "$ledger"; then
        /bin/mv -f "$packet" "$processed/$packet_id.duplicate.json"
        continue
    fi

    work_dir="$work_root/$packet_id"
    candidates="$work_dir/candidates"
    runtime_artifacts="$work_dir/runtime-artifacts"
    /bin/mkdir -p "$candidates" "$runtime_artifacts"
    /bin/cp "$packet" "$work_dir/packet.json"
    /bin/cp "$provenance" "$work_dir/provenance.json"
    if ! /usr/bin/python3 -I -S "$OPS_ROOT/bin/h264-seed-mutator.py" generate \
        "$packet" --corpus "$corpus" --output "$candidates" > "$work_dir/generated.txt"; then
        echo "[seed-admission] generation failed packet=$packet_id; inbox preserved" >&2
        continue
    fi

    admitted=0
    rejected=0
    rejected_signal=0
    for candidate in "$candidates"/*.h264; do
        name="$(/usr/bin/basename "$candidate")"
        log="$work_dir/$name.validation.log"
        set +e
        "$binary" -runs=1 -timeout=30 -rss_limit_mb=4096 \
            "-artifact_prefix=$runtime_artifacts/" "$candidate" > "$log" 2>&1
        rc=$?
        set -e
        signal=0
        if /usr/bin/grep -Eq \
            'ERROR: AddressSanitizer|SUMMARY: AddressSanitizer|UndefinedBehaviorSanitizer|MemorySanitizer|ThreadSanitizer|runtime error:|libFuzzer: deadly signal' \
            "$log"; then
            signal=1
        fi
        sha256="$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{print $1}')"
        if [ "$rc" -eq 0 ] && [ "$signal" -eq 0 ]; then
            destination="$corpus/seed-$sha256"
            if [ ! -f "$destination" ]; then
                temporary="$corpus/.seed-$sha256.partial.$$"
                /bin/cp "$candidate" "$temporary"
                /bin/chmod 600 "$temporary"
                /bin/mv -f "$temporary" "$destination"
            fi
            admitted=$((admitted + 1))
        else
            candidate_quarantine="$quarantine/$packet_id-$name"
            /bin/mkdir -p "$candidate_quarantine"
            /bin/cp "$candidate" "$candidate_quarantine/"
            /bin/cp "$log" "$candidate_quarantine/"
            /bin/cp "$packet" "$candidate_quarantine/packet.json"
            rejected=$((rejected + 1))
            if [ "$signal" -eq 1 ]; then
                rejected_signal=$((rejected_signal + 1))
            fi
        fi
    done
    source_kind="$(/usr/bin/jq -r '.source.kind' "$packet")"
    source_id="$(/usr/bin/jq -r '.source.id' "$packet" | /usr/bin/tr '\t\r\n' ' ')"
    /usr/bin/jq -n \
        --arg completed_at "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg packet_id "$packet_id" \
        --arg source_kind "$source_kind" \
        --arg source_id "$source_id" \
        --arg target "$target" \
        --argjson admitted "$admitted" \
        --argjson rejected "$rejected" \
        --argjson rejected_signal "$rejected_signal" \
        '{schema:"chromium-media-h264-admission-v1",completed_at:$completed_at,packet_id:$packet_id,source_kind:$source_kind,source_id:$source_id,target:$target,admitted:$admitted,rejected:$rejected,rejected_signal:$rejected_signal,auto_promote:false,human_triage_required:true}' \
        > "$work_dir/result.json"
    /usr/bin/printf '%s\t%s\t%s\tadmitted=%s\trejected=%s\t%s\n' \
        "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$packet_id" "$source_kind" "$admitted" "$rejected" "$source_id" >> "$ledger"
    /bin/mv -f "$packet" "$processed/$packet_id.json"
    echo "[seed-admission] packet=$packet_id admitted=$admitted rejected=$rejected auto_promote=false"
    if [ "$rejected" -gt 0 ]; then
        alert_payload="$work_dir/discord-alert.json"
        content="Chromium M1 H264 seed admission runtime reject
host: $(/bin/hostname)
target: $target
packet_id: $packet_id
source: $source_kind/$source_id
admitted: $admitted
rejected: $rejected
sanitizer_signal_rejects: $rejected_signal
triage_bundle: ${work_dir#$DATA_ROOT/}
quarantine_root: ${quarantine#$DATA_ROOT/}
auto_promote: false
human_triage_required: true"
        /usr/bin/jq -n --arg content "$content" '{content:$content}' > "$alert_payload"
        if ! "$OPS_ROOT/bin/discord-send.sh" "$DISCORD_CRASH_CHANNEL_ID" "$alert_payload"; then
            echo "[seed-admission] Discord alert failed packet=$packet_id" >&2
        fi
    fi
done
