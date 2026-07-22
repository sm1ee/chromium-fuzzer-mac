#!/bin/bash
set -euo pipefail

OPS_ROOT="/Users/smlee/chromium-worker-ops"
# shellcheck source=/dev/null
source "$OPS_ROOT/config/worker.env"

target="${1:-$PRIMARY_TARGET}"
binary="$OUT_DIR/$target"
metrics_file="$DATA_ROOT/metrics/$target.provenance.json"
/bin/mkdir -p "$DATA_ROOT/metrics"

now="$(/bin/date +%s)"
head_value="missing"
expected_head="missing"
expected_epoch="0"
dirty_count="-1"
checkout_age="-1"
args_hash="missing"
args_valid=0
binary_size="0"
binary_mtime="0"
binary_age="-1"
binary_fingerprint="missing"
v8_head="missing"
angle_head="missing"
dawn_head="missing"
ffmpeg_head="missing"
deps_dirty=0
reason="source_missing"
eligible=0
ops_source_head="missing"
ops_integrity=0
host_arch="$(/usr/bin/uname -m)"
metal_version="missing"
metal_component_build="missing"
metal_ready=0

repo_head() {
    repo="$1"
    if [ -d "$repo/.git" ]; then
        /usr/bin/git -C "$repo" rev-parse HEAD 2>/dev/null || /usr/bin/printf 'unknown\n'
    else
        /usr/bin/printf 'missing\n'
    fi
}

repo_dirty_count() {
    repo="$1"
    if [ -d "$repo/.git" ]; then
        /usr/bin/git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null |
            /usr/bin/wc -l | /usr/bin/tr -d ' '
    else
        /usr/bin/printf '0\n'
    fi
}

if [ -d "$SRC_ROOT/.git" ]; then
    head_value="$(/usr/bin/git -C "$SRC_ROOT" rev-parse HEAD)"
    dirty_count="$(repo_dirty_count "$SRC_ROOT")"
    v8_head="$(repo_head "$SRC_ROOT/v8")"
    angle_head="$(repo_head "$SRC_ROOT/third_party/angle")"
    dawn_head="$(repo_head "$SRC_ROOT/third_party/dawn")"
    ffmpeg_head="$(repo_head "$SRC_ROOT/third_party/ffmpeg")"
    deps_dirty=$(( $(repo_dirty_count "$SRC_ROOT/v8") + $(repo_dirty_count "$SRC_ROOT/third_party/angle") + $(repo_dirty_count "$SRC_ROOT/third_party/dawn") + $(repo_dirty_count "$SRC_ROOT/third_party/ffmpeg") ))
fi

if [ -f "$EXPECTED_HEAD_FILE" ]; then
    read -r expected_head expected_epoch < "$EXPECTED_HEAD_FILE"
    checkout_age=$(( now - expected_epoch ))
fi
if [ -f "$OPS_ROOT/deploy-head.txt" ]; then
    ops_source_head="$(/usr/bin/tr -d '\r\n' < "$OPS_ROOT/deploy-head.txt")"
fi
if [ -f "$OPS_ROOT/deploy-manifest.tsv" ] &&
   (cd "$OPS_ROOT" && /usr/bin/shasum -a 256 -c deploy-manifest.tsv >/dev/null 2>&1); then
    ops_integrity=1
fi

if [ -f "$OUT_DIR/args.gn" ]; then
    args_hash="$(/usr/bin/shasum -a 256 "$OUT_DIR/args.gn" | /usr/bin/awk '{print $1}')"
    if /usr/bin/grep -Eq '^[[:space:]]*is_asan[[:space:]]*=[[:space:]]*true' "$OUT_DIR/args.gn" &&
       /usr/bin/grep -Eq '^[[:space:]]*use_libfuzzer[[:space:]]*=[[:space:]]*true' "$OUT_DIR/args.gn" &&
       /usr/bin/grep -Eq '^[[:space:]]*target_cpu[[:space:]]*=[[:space:]]*"arm64"' "$OUT_DIR/args.gn"; then
        args_valid=1
    fi
fi

if [ -f "$binary" ]; then
    binary_size="$(/usr/bin/stat -f '%z' "$binary")"
    binary_mtime="$(/usr/bin/stat -f '%m' "$binary")"
    binary_age=$(( now - binary_mtime ))
    binary_fingerprint="stat-${binary_size}-${binary_mtime}"
fi

if metal_output="$(/usr/bin/xcrun metal --version 2>/dev/null)"; then
    metal_version="$(/usr/bin/printf '%s\n' "$metal_output" | /usr/bin/head -n 1)"
    metal_ready=1
fi
if component_json="$(/usr/bin/xcodebuild -showComponent MetalToolchain -json 2>/dev/null)"; then
    metal_component_build="$(/usr/bin/printf '%s\n' "$component_json" | /usr/bin/jq -r '.buildVersion // "missing"')"
fi

if [ ! -d "$SRC_ROOT/.git" ]; then
    reason="source_missing"
elif [ "$ops_source_head" = "missing" ]; then
    reason="ops_deploy_unattested"
elif [ "$ops_integrity" != "1" ]; then
    reason="ops_deploy_dirty"
elif [ "$host_arch" != "arm64" ]; then
    reason="wrong_architecture"
elif [ "$metal_ready" != "1" ]; then
    reason="metal_toolchain_missing"
elif [ "$expected_head" = "missing" ]; then
    reason="expected_head_missing"
elif [ "$head_value" != "$expected_head" ]; then
    reason="head_mismatch"
elif [ "$dirty_count" != "0" ] || [ "$deps_dirty" != "0" ]; then
    reason="source_dirty"
elif [ "$checkout_age" -lt 0 ] || [ "$checkout_age" -gt "$MAX_CHECKOUT_AGE_SECS" ]; then
    reason="stale_checkout"
elif [ "$args_valid" != "1" ]; then
    reason="args_missing_or_mismatch"
elif [ ! -f "$binary" ]; then
    reason="binary_missing"
elif [ "$binary_age" -lt 0 ] || [ "$binary_age" -gt "$MAX_BINARY_AGE_SECS" ]; then
    reason="old_binary"
else
    reason="current_tree_ready"
    eligible=1
fi

support_only=1
if [ "$eligible" = "1" ]; then support_only=0; fi

xcode_version="$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/tr '\n' ';' || true)"
os_version="$(/usr/bin/sw_vers -productVersion)"
host_name="$(/bin/hostname)"

temp_file="$metrics_file.tmp.$$"
/usr/bin/jq -n \
    --arg generated_at "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg host "$host_name" \
    --arg host_arch "$host_arch" \
    --arg target "$target" \
    --arg binary "$binary" \
    --arg source_head "$head_value" \
    --arg expected_head "$expected_head" \
    --arg ops_source_head "$ops_source_head" \
    --arg v8_head "$v8_head" \
    --arg angle_head "$angle_head" \
    --arg dawn_head "$dawn_head" \
    --arg ffmpeg_head "$ffmpeg_head" \
    --arg args_sha256 "$args_hash" \
    --arg binary_fingerprint "$binary_fingerprint" \
    --arg xcode "$xcode_version" \
    --arg metal_version "$metal_version" \
    --arg metal_component_build "$metal_component_build" \
    --arg os_version "$os_version" \
    --arg reason "$reason" \
    --argjson source_dirty_count "$dirty_count" \
    --argjson dependency_dirty_count "$deps_dirty" \
    --argjson checkout_age_secs "$checkout_age" \
    --argjson binary_age_secs "$binary_age" \
    --argjson binary_size "$binary_size" \
    --argjson args_valid "$args_valid" \
    --argjson metal_ready "$metal_ready" \
    --argjson ops_integrity "$ops_integrity" \
    --argjson current_tree_eligible "$eligible" \
    --argjson support_only "$support_only" \
    --argjson detection_kpi_eligible "$eligible" \
    '{generated_at:$generated_at,host:$host,host_arch:$host_arch,platform:"macos-arm64",target:$target,binary:$binary,source_head:$source_head,expected_head:$expected_head,ops_source_head:$ops_source_head,ops_integrity:$ops_integrity,v8_head:$v8_head,angle_head:$angle_head,dawn_head:$dawn_head,ffmpeg_head:$ffmpeg_head,source_dirty_count:$source_dirty_count,dependency_dirty_count:$dependency_dirty_count,checkout_age_secs:$checkout_age_secs,args_sha256:$args_sha256,args_valid:$args_valid,binary_fingerprint:$binary_fingerprint,binary_size:$binary_size,binary_age_secs:$binary_age_secs,xcode:$xcode,metal_version:$metal_version,metal_component_build:$metal_component_build,metal_ready:$metal_ready,os_version:$os_version,current_tree_eligible:$current_tree_eligible,support_only:$support_only,detection_kpi_eligible:$detection_kpi_eligible,reason:$reason}' > "$temp_file"
/bin/chmod 600 "$temp_file"
/bin/mv -f "$temp_file" "$metrics_file"
/bin/cat "$metrics_file"
