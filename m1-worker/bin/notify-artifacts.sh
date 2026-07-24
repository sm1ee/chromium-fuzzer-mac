#!/bin/bash
set -euo pipefail
shopt -s nullglob

OPS_ROOT="/Users/smlee/chromium-worker-ops"
# shellcheck source=/dev/null
source "$OPS_ROOT/config/worker.env"

/bin/mkdir -p "$DATA_ROOT/state" "$DATA_ROOT/logs"
lock_dir="$DATA_ROOT/state/discord-artifact-notifier.lockdir"
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
    exit 0
fi
cleanup() { /bin/rmdir "$lock_dir" 2>/dev/null || true; }
trap cleanup EXIT

state_file="$DATA_ROOT/state/discord-notified-artifacts.txt"
/usr/bin/touch "$state_file"
/bin/chmod 600 "$state_file"
state_lines="$(/usr/bin/wc -l < "$state_file" | /usr/bin/tr -d ' ')"
if [ "$state_lines" -gt 50000 ]; then
    /usr/bin/tail -n 50000 "$state_file" > "$state_file.tmp.$$"
    /bin/mv -f "$state_file.tmp.$$" "$state_file"
fi

artifact_root="$DATA_ROOT/artifacts/$PRIMARY_TARGET"
[ -d "$artifact_root" ] || exit 0
candidates="$(/usr/bin/mktemp "$DATA_ROOT/state/discord-candidates.XXXXXX")"
payload="$(/usr/bin/mktemp "$DATA_ROOT/state/discord-payload.XXXXXX")"
cleanup_files() { /bin/rm -f "$candidates" "$payload"; cleanup; }
trap cleanup_files EXIT
/usr/bin/find "$artifact_root" -type f -path '*/crashes/*' -print | /usr/bin/sort > "$candidates"

while IFS= read -r artifact; do
    filename="$(/usr/bin/basename "$artifact")"
    case "$filename" in
        crash-*|leak-*|asan-*|ubsan-*|msan-*|tsan-*) ;;
        *) continue ;;
    esac
    sha256="$(/usr/bin/shasum -a 256 "$artifact" | /usr/bin/awk '{print $1}')"
    fingerprint="$PRIMARY_TARGET:$sha256:$artifact"
    if /usr/bin/grep -Fqx "$fingerprint" "$state_file"; then
        continue
    fi

    session_dir="$(/usr/bin/dirname "$(/usr/bin/dirname "$artifact")")"
    manifest="$session_dir/manifest.json"
    if [ ! -f "$manifest" ] ||
       ! /usr/bin/jq -e '.current_tree_eligible == 1 and .support_only == 0 and .detection_kpi_eligible == 1 and .ops_integrity == 1' "$manifest" >/dev/null; then
        echo "skip non-current artifact: $artifact" >&2
        /usr/bin/printf '%s\n' "$fingerprint" >> "$state_file"
        continue
    fi

    size_bytes="$(/usr/bin/stat -f '%z' "$artifact")"
    source_head="$(/usr/bin/jq -r '.source_head' "$manifest")"
    ops_head="$(/usr/bin/jq -r '.ops_source_head' "$manifest")"
    rel_path="${artifact#$DATA_ROOT/}"
    log_files=("$session_dir"/logs/*.log)
    asan_markers=0
    sanitizer_markers=0
    if [ "${#log_files[@]}" -gt 0 ]; then
        asan_markers="$(/usr/bin/awk '/ERROR: AddressSanitizer|SUMMARY: AddressSanitizer/ {count++} END {print count + 0}' "${log_files[@]}")"
        sanitizer_markers="$(/usr/bin/awk '/AddressSanitizer|UndefinedBehaviorSanitizer|MemorySanitizer|ThreadSanitizer|runtime error:|libFuzzer: deadly signal/ {count++} END {print count + 0}' "${log_files[@]}")"
    fi

    session_name="$(/usr/bin/basename "$session_dir")"
    bundle_dir="$DATA_ROOT/triage/$PRIMARY_TARGET/$session_name-${sha256:0:16}"
    /bin/mkdir -p "$bundle_dir"
    /bin/chmod 700 "$bundle_dir"
    if [ ! -f "$bundle_dir/$filename" ]; then
        /bin/cp "$artifact" "$bundle_dir/$filename"
    fi
    /bin/cp "$manifest" "$bundle_dir/manifest.json"
    if [ ! -f "$bundle_dir/logs.tar.gz" ]; then
        if ! /usr/bin/tar -czf "$bundle_dir/logs.tar.gz" -C "$session_dir" logs; then
            echo "failed to preserve raw logs for artifact: $artifact" >&2
            continue
        fi
    fi
    if [ "${#log_files[@]}" -gt 0 ]; then
        /usr/bin/grep -nEh \
            'AddressSanitizer|UndefinedBehaviorSanitizer|MemorySanitizer|ThreadSanitizer|runtime error:|libFuzzer: deadly signal' \
            "${log_files[@]}" 2>/dev/null | /usr/bin/head -n 200 \
            > "$bundle_dir/sanitizer-excerpt.txt" || true
    else
        : > "$bundle_dir/sanitizer-excerpt.txt"
    fi
    logs_sha256="$(/usr/bin/shasum -a 256 "$bundle_dir/logs.tar.gz" | /usr/bin/awk '{print $1}')"
    /usr/bin/jq -n \
        --arg created_at "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg target "$PRIMARY_TARGET" \
        --arg artifact "$filename" \
        --arg artifact_sha256 "$sha256" \
        --arg logs_sha256 "$logs_sha256" \
        --arg source_head "$source_head" \
        --arg ops_head "$ops_head" \
        --arg session "${session_dir#$DATA_ROOT/}" \
        --argjson artifact_size_bytes "$size_bytes" \
        --argjson asan_markers "$asan_markers" \
        --argjson sanitizer_markers "$sanitizer_markers" \
        '{schema:"chromium-m1-crash-triage-bundle-v1",created_at:$created_at,target:$target,artifact:$artifact,artifact_sha256:$artifact_sha256,artifact_size_bytes:$artifact_size_bytes,logs_archive:"logs.tar.gz",logs_sha256:$logs_sha256,source_head:$source_head,ops_head:$ops_head,session:$session,asan_markers:$asan_markers,sanitizer_markers:$sanitizer_markers,auto_promote:false,human_triage_required:true}' \
        > "$bundle_dir/metadata.json"
    rel_bundle="${bundle_dir#$DATA_ROOT/}"

    /usr/bin/python3 -I -S - "$artifact" "$PRIMARY_TARGET" "$filename" "$size_bytes" "$rel_path" "$sha256" "$source_head" "$ops_head" "$asan_markers" "$sanitizer_markers" "$rel_bundle" > "$payload" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

path = pathlib.Path(sys.argv[1])
target, filename, size_bytes, rel_path = sys.argv[2:6]
sha256, source_head, ops_head, asan_markers = sys.argv[6:10]
sanitizer_markers, rel_bundle = sys.argv[10:12]
with path.open("rb") as handle:
    sample = handle.read(64)
try:
    preview = sample.decode("utf-8")
    if "\x00" in preview or not all(c.isprintable() or c in "\r\n\t" for c in preview):
        raise UnicodeError
    preview = preview.strip() or "[empty text preview]"
except (UnicodeError, UnicodeDecodeError):
    preview = "[hex preview] " + " ".join(f"{b:02x}" for b in sample)

if int(asan_markers):
    signal = "ASAN runtime marker"
elif int(sanitizer_markers):
    signal = "sanitizer/runtime marker"
else:
    signal = "libFuzzer artifact; triage required"
content = (
    "Chromium fuzz artifact detected on M1 Max\n"
    f"time_utc: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
    f"target: {target}\nfile: {filename}\nsize: {size_bytes} bytes\n"
    f"sha256: {sha256}\nsource_head: {source_head}\nops_head: {ops_head}\n"
    f"runtime_signal: {signal}\nauto_promote: false\npath: {rel_path}\n"
    f"triage_bundle: {rel_bundle}\n"
    "bundle_files: artifact, manifest.json, metadata.json, sanitizer-excerpt.txt, logs.tar.gz\n"
    f"preview: {preview}"
)
print(json.dumps({"content": content[:1900]}, ensure_ascii=False))
PY
    if "$OPS_ROOT/bin/discord-send.sh" "$DISCORD_CRASH_CHANNEL_ID" "$payload"; then
        /usr/bin/printf '%s\n' "$fingerprint" >> "$state_file"
    fi
done < "$candidates"
