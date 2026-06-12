#!/usr/bin/env bash
set -euo pipefail
export PYTHONNOUSERSITE="${PYTHONNOUSERSITE:-1}"

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
LOG_DIR="$ROOT/fuzz/logs"
MANAGED_ARTIFACT_ROOT="$ROOT/fuzz/managed/artifacts"
EXTRA_ARTIFACT_ROOT="${EXTRA_ARTIFACT_ROOT:-$MANAGED_ARTIFACT_ROOT}"
LEGACY_EXTRA_ARTIFACT_ROOT="${LEGACY_EXTRA_ARTIFACT_ROOT:-/tmp/chromium-vrp-fuzz/artifacts}"
REGISTRY_QUERY_PY="$ROOT/fuzz/managed/registry_query.py"
STATUS_SESSION_LOOKBACK_COUNT="${STATUS_SESSION_LOOKBACK_COUNT:-8}"
ARTIFACT_FILE_SCAN_LIMIT="${ARTIFACT_FILE_SCAN_LIMIT:-2000}"
STALE_STOPPED_SESSION_SECS="${STALE_STOPPED_SESSION_SECS:-604800}"
FRESH_BINARY_MAX_AGE_SECS="${FRESH_BINARY_MAX_AGE_SECS:-604800}"
FUZZ_STATUS_HASH_BINARIES="${FUZZ_STATUS_HASH_BINARIES:-0}"
PYTHON_BIN="${PYTHON_BIN:-/Users/bugclaw/.openclaw/workspace/depot_tools/bootstrap-2@3.11.8.chromium.35_bin/python3/bin/python3}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="/opt/homebrew/bin/python3"
fi

FUZZERS=()
while IFS= read -r fuzzer; do
  [[ -n "$fuzzer" ]] && FUZZERS+=("$fuzzer")
done < <("$PYTHON_BIN" -S "$REGISTRY_QUERY_PY" managed-targets)

if (( $# > 0 )); then
  FUZZERS=("$@")
fi

process_snapshot="$(ps -axww -o pid=,etime=,rss=,command= 2>/dev/null || true)"

first_existing_path() {
  local candidate=""
  for candidate in "$@"; do
    if [[ -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "$1"
}

file_mtime_epoch() {
  local path="$1"
  stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path" 2>/dev/null || echo 0
}

artifact_files_for_scan() {
  local artifact_dir="$1"
  [[ -d "$artifact_dir" ]] || return 0
  "$PYTHON_BIN" -S - "$artifact_dir" "$ARTIFACT_FILE_SCAN_LIMIT" <<'PY'
import os
import sys

root, limit_s = sys.argv[1:3]
limit = int(limit_s)
entries = []
try:
    with os.scandir(root) as scan:
        for entry in scan:
            try:
                if not entry.is_file(follow_symlinks=False):
                    continue
                st = entry.stat(follow_symlinks=False)
                entries.append((st.st_mtime, entry.path))
            except OSError:
                continue
except OSError:
    sys.exit(0)

entries.sort(reverse=True)
for _, path in entries[:limit]:
    print(path)
PY
}

INDEXEDDB_STATEFUL_BINARY="$(
  first_existing_path \
    "$ROOT/src/out/libfuzzer-narrow-linux/indexed_db_leveldb_coding_sequence_fuzztest_IndexedDbLevelDbCodingSequenceFuzzTest_IndexedDbCodingStatefulSequence_fuzzer" \
    "$ROOT/src/out/libfuzzer-current/indexed_db_leveldb_coding_sequence_fuzztest_IndexedDbLevelDbCodingSequenceFuzzTest_IndexedDbCodingStatefulSequence_fuzzer" \
    "$ROOT/src/out/libfuzzer-trend/indexed_db_leveldb_coding_sequence_fuzztest_IndexedDbLevelDbCodingSequenceFuzzTest_IndexedDbCodingStatefulSequence_fuzzer"
)"

artifact_dirs_for() {
  if "$PYTHON_BIN" -S "$REGISTRY_QUERY_PY" artifact-dirs "$1" 2>/dev/null; then
    return 0
  fi

  case "$1" in
    v8_script_parser_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/v8_script_parser_parallel"
      printf '%s\n' "$EXTRA_ARTIFACT_ROOT/v8/v8_script_parser_fuzzer"
      printf '%s\n' "$LEGACY_EXTRA_ARTIFACT_ROOT/v8/v8_script_parser_fuzzer"
      ;;
    angle_translator_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/angle_translator"
      printf '%s\n' "$EXTRA_ARTIFACT_ROOT/gpu/angle_translator_fuzzer"
      printf '%s\n' "$LEGACY_EXTRA_ARTIFACT_ROOT/gpu/angle_translator_fuzzer"
      ;;
    angle_texture_vk_pitch_narrow_fuzzer)
      printf '%s\n' "$EXTRA_ARTIFACT_ROOT/gpu/angle_texture_vk_pitch_narrow_fuzzer"
      printf '%s\n' "$LEGACY_EXTRA_ARTIFACT_ROOT/gpu/angle_texture_vk_pitch_narrow_fuzzer"
      ;;
    tint_wgsl_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/tint_wgsl"
      printf '%s\n' "$EXTRA_ARTIFACT_ROOT/gpu/tint_wgsl_fuzzer"
      printf '%s\n' "$LEGACY_EXTRA_ARTIFACT_ROOT/gpu/tint_wgsl_fuzzer"
      ;;
    webcodecs_video_decoder_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/webcodecs_video_decoder"
      printf '%s\n' "$EXTRA_ARTIFACT_ROOT/webcodecs/webcodecs_video_decoder_fuzzer"
      printf '%s\n' "$LEGACY_EXTRA_ARTIFACT_ROOT/webcodecs/webcodecs_video_decoder_fuzzer"
      ;;
    css_parser_fast_paths_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/css_parser_fast_paths"
      ;;
    webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SingleOpGru_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SingleOpGru_fuzzer"
      ;;
    webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SingleOpLstm_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SingleOpLstm_fuzzer"
      ;;
    webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SingleOpConv2d_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SingleOpConv2d_fuzzer"
      ;;
    webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SingleOpGemm_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SingleOpGemm_fuzzer"
      ;;
    webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SingleOpPool2d_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SingleOpPool2d_fuzzer"
      ;;
    webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SubgraphDQConv2dQ_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SubgraphDQConv2dQ_fuzzer"
      ;;
    webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SubgraphDQPool2dQ_fuzzer)
      printf '%s\n' "$LOG_DIR/artifacts/webnn_graph_impl_fuzzer_WebNNGraphImplFuzzer_CPU_SubgraphDQPool2dQ_fuzzer"
      ;;
    mojo_core_channel_fuzzer)
      printf '%s\n' "$EXTRA_ARTIFACT_ROOT/mojo/mojo_core_channel_fuzzer"
      printf '%s\n' "$LEGACY_EXTRA_ARTIFACT_ROOT/mojo/mojo_core_channel_fuzzer"
      ;;
    audio_processing_fuzzer)
      printf '%s\n' "$EXTRA_ARTIFACT_ROOT/audio/audio_processing_fuzzer"
      printf '%s\n' "$LEGACY_EXTRA_ARTIFACT_ROOT/audio/audio_processing_fuzzer"
      ;;
    indexed_db_leveldb_coding_decodeidbkey_fuzzer)
      printf '%s\n' "$EXTRA_ARTIFACT_ROOT/indexeddb/indexed_db_leveldb_coding_decodeidbkey_fuzzer"
      printf '%s\n' "$LEGACY_EXTRA_ARTIFACT_ROOT/indexeddb/indexed_db_leveldb_coding_decodeidbkey_fuzzer"
      ;;
    *)
      printf '%s\n' "$LOG_DIR/artifacts/$1"
      ;;
  esac
}

session_candidates_under() {
  local parent="$1"
  [[ -d "$parent" ]] || return 0
  "$PYTHON_BIN" -S - "$parent" "$STATUS_SESSION_LOOKBACK_COUNT" <<'PY'
import os
import sys

parent, limit_s = sys.argv[1:3]
limit = max(1, int(limit_s))
names = []
try:
    with os.scandir(parent) as scan:
        for entry in scan:
            if not entry.is_dir(follow_symlinks=False):
                continue
            names.append(entry.name)
except OSError:
    raise SystemExit(0)

# Managed session directories are timestamp-like. Sorting by name avoids a stat
# on every artifact entry and keeps status checks cheap on large crash trees.
for name in sorted(names)[-limit:]:
    print(os.path.join(parent, name))
PY
}

latest_session_dir_for() {
  local fuzzer="$1"
  local candidate=""
  local session=""
  local best=""

  session_mtime() {
    local dir="$1"
    local probe="$dir"
    [[ -f "$dir/logs/run.log" ]] && probe="$dir/logs/run.log"
    stat -f '%m' "$probe" 2>/dev/null || stat -c '%Y' "$probe" 2>/dev/null || echo 0
  }

  emit_session_candidate() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    [[ -f "$dir/logs/run.log" || -d "$dir/crashes" || -d "$dir/notes" ]] || return 0
    printf '%s\t%s\n' "$(session_mtime "$dir")" "$dir"
  }

  while IFS= read -r candidate; do
    [[ -d "$candidate" ]] || continue
    if [[ -f "$candidate/logs/run.log" ]]; then
      emit_session_candidate "$candidate"
      continue
    fi

    while IFS= read -r session; do
      emit_session_candidate "$session"
    done < <(session_candidates_under "$candidate")
  done < <(artifact_dirs_for "$fuzzer") |
    sort -n |
    tail -n 1 |
    cut -f2-
}

latest_log_for() {
  local fuzzer="$1"
  local session_dir=""

  session_dir="$(latest_session_dir_for "$fuzzer")"
  if [[ -n "$session_dir" && -f "$session_dir/logs/run.log" ]]; then
    printf '%s\n' "$session_dir/logs/run.log"
    return 0
  fi

  printf '%s\n' "$LOG_DIR/${fuzzer}.log"
}

latest_exit_code_for() {
  local fuzzer="$1"
  local session_dir=""
  session_dir="$(latest_session_dir_for "$fuzzer")"
  if [[ -z "$session_dir" || ! -f "$session_dir/notes/exit_code.txt" ]]; then
    return 0
  fi
  tr -d '\r\n' <"$session_dir/notes/exit_code.txt"
}

latest_max_total_time_for() {
  local fuzzer="$1"
  local session_dir=""
  local cmd_file=""
  local max_total_time=""

  session_dir="$(latest_session_dir_for "$fuzzer")"
  cmd_file="$session_dir/notes/command.txt"
  if [[ -z "$session_dir" || ! -f "$cmd_file" ]]; then
    return 0
  fi

  max_total_time="$(sed -n 's/.*-max_total_time=\([0-9][0-9]*\).*/\1/p' "$cmd_file" | tail -n 1)"
  if [[ -n "$max_total_time" ]]; then
    printf '%s\n' "$max_total_time"
  fi
}

artifact_summary_for() {
  local fuzzer="$1"
  local session_dir=""
  local artifact_dir=""
  local crash_count=0
  local slow_count=0
  local timeout_count=0
  local oom_count=0
  local leak_count=0
  local other_count=0

  classify_artifact() {
    local name="$1"
    case "$name" in
      slow-unit-*) slow_count=$((slow_count + 1)) ;;
      timeout-*) timeout_count=$((timeout_count + 1)) ;;
      oom-*) oom_count=$((oom_count + 1)) ;;
      leak-*) leak_count=$((leak_count + 1)) ;;
      crash-*|asan-*|ubsan-*|msan-*|tsan-*) crash_count=$((crash_count + 1)) ;;
      *) other_count=$((other_count + 1)) ;;
    esac
  }

  session_dir="$(latest_session_dir_for "$fuzzer")"
  if [[ -n "$session_dir" && -d "$session_dir/crashes" ]]; then
    while IFS= read -r artifact_path; do
      classify_artifact "$(basename "$artifact_path")"
    done < <(artifact_files_for_scan "$session_dir/crashes")
    printf 'crash=%s slow=%s timeout=%s oom=%s leak=%s other=%s\n' \
      "$crash_count" "$slow_count" "$timeout_count" "$oom_count" "$leak_count" "$other_count"
    return 0
  fi

  while IFS= read -r artifact_dir; do
    [[ -d "$artifact_dir" ]] || continue
    while IFS= read -r artifact_path; do
      classify_artifact "$(basename "$artifact_path")"
    done < <(artifact_files_for_scan "$artifact_dir")
  done < <(artifact_dirs_for "$fuzzer")

  printf 'crash=%s slow=%s timeout=%s oom=%s leak=%s other=%s\n' \
    "$crash_count" "$slow_count" "$timeout_count" "$oom_count" "$leak_count" "$other_count"
}

latest_log_summary_for() {
  local log_file="$1"
  "$PYTHON_BIN" - "$log_file" <<'PY'
import pathlib
import re
import sys

log_path = pathlib.Path(sys.argv[1])
if not log_path.is_file():
    print("no log yet")
    sys.exit(0)

def tail_lines(path: pathlib.Path, max_lines: int = 400, max_bytes: int = 262144):
    size = path.stat().st_size
    with path.open("rb") as f:
        f.seek(max(0, size - max_bytes))
        data = f.read()
    return data.decode("utf-8", errors="replace").splitlines()[-max_lines:]

lines = tail_lines(log_path)
alert_re = re.compile(r'(AddressSanitizer|UndefinedBehaviorSanitizer|deadly signal|ERROR:)')
stat_re = re.compile(
    r'(?:#\d+\s+(?:pulse|NEW|REDUCE|INITED|DONE)\s+.*?ft:\s*(\d+).*?corp:\s*(\d+)/([^\s]+).*?exec/s:\s*(\d+).*?rss:\s*(\d+)Mb)',
    re.IGNORECASE,
)
lim_re = re.compile(r'lim:\s*([^\s]+)')
done_re = re.compile(r'^Done (\d+) runs in (\d+) second\(s\)$')

last_alert = ""
last_stats = ""
last_done = ""

for line in lines:
    compact = " ".join(line.split())
    if alert_re.search(compact):
        last_alert = compact[:220]
    stat_match = stat_re.search(compact)
    if stat_match:
        lim_match = lim_re.search(compact)
        lim = lim_match.group(1) if lim_match else "-"
        ft, corp_count, corp_size, exec_s, rss = stat_match.groups()
        last_stats = f"ft {ft} | corpus {corp_count}/{corp_size} | exec/s {exec_s} | fuzz_rss {rss}MB | lim {lim}"
    done_match = done_re.search(compact)
    if done_match:
        runs, seconds = done_match.groups()
        last_done = f"runs {runs} | seconds {seconds}"

parts = []
if last_stats:
    parts.append(last_stats)
if last_done:
    parts.append(last_done)
if last_alert:
    parts.append(f"last_alert {last_alert}")

print(" || ".join(parts) if parts else "no structured stats yet")
PY
}

latest_lane_packet_for() {
  local fuzzer="$1"
  local session_dir=""

  session_dir="$(latest_session_dir_for "$fuzzer")"
  if [[ -n "$session_dir" && -f "$session_dir/notes/lane_packet.json" ]]; then
    printf '%s\n' "$session_dir/notes/lane_packet.json"
  fi
}

latest_binary_for() {
  local fuzzer="$1"
  local session_dir=""
  local packet_file=""
  local cmd_file=""

  session_dir="$(latest_session_dir_for "$fuzzer")"
  if [[ -z "$session_dir" ]]; then
    return 0
  fi
  packet_file="$session_dir/notes/lane_packet.json"
  cmd_file="$session_dir/notes/command.txt"

  if [[ -n "$session_dir" && -f "$packet_file" ]]; then
    "$PYTHON_BIN" -S - "$packet_file" <<'PY'
import json
import pathlib
import sys

try:
    packet = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace"))
    print(packet.get("runtime", {}).get("binary", ""))
except Exception:
    print("")
PY
    return 0
  fi

  if [[ -n "$session_dir" && -f "$cmd_file" ]]; then
    "$PYTHON_BIN" -S - "$cmd_file" <<'PY'
import pathlib
import shlex
import sys

try:
    parts = shlex.split(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace"))
    print(parts[0] if parts else "")
except Exception:
    print("")
PY
  fi
}

binary_evidence_summary_for() {
  local binary="$1"
  "$PYTHON_BIN" -S - "$binary" "$FRESH_BINARY_MAX_AGE_SECS" "$FUZZ_STATUS_HASH_BINARIES" <<'PY'
import datetime as dt
import hashlib
import pathlib
import sys
import time

binary = pathlib.Path(sys.argv[1]) if sys.argv[1] else None
fresh_max = int(sys.argv[2])
hash_enabled = sys.argv[3] == "1"

if not binary:
    print("binary unknown | support_only=1 | detection_kpi_eligible=0 | reason=no_binary_metadata")
    raise SystemExit(0)
if not binary.exists():
    print(f"binary {binary} | missing | support_only=1 | detection_kpi_eligible=0 | reason=binary_missing")
    raise SystemExit(0)

st = binary.stat()
age = max(0, int(time.time() - st.st_mtime))
age_days = age / 86400
mtime = dt.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
support_only = 1 if age > fresh_max else 0
eligible = 0 if support_only else 1
reason = "old_binary" if support_only else "fresh_binary"
parts = [
    f"binary {binary}",
    f"mtime {mtime}",
    f"age_days {age_days:.1f}",
    f"size_mb {st.st_size / (1024 * 1024):.1f}",
    f"support_only={support_only}",
    f"detection_kpi_eligible={eligible}",
    f"reason={reason}",
]
if hash_enabled:
    digest = hashlib.sha256()
    with binary.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    parts.append(f"sha256={digest.hexdigest()}")
else:
    parts.append("sha256=skipped")
print(" | ".join(parts))
PY
}

lane_diversity_summary_for() {
  local fuzzer="$1"
  local packet_file="$2"
  local log_file="$3"

  "$PYTHON_BIN" - "$fuzzer" "$packet_file" "$log_file" <<'PY'
import json
import os
import pathlib
import sys

fuzzer = sys.argv[1]
packet_path = pathlib.Path(sys.argv[2])
log_path = pathlib.Path(sys.argv[3])
deep_scan = os.environ.get("FUZZ_STATUS_DEEP_SCAN", "0") == "1"
max_corpus_scan = int(os.environ.get("FUZZ_STATUS_MAX_CORPUS_SCAN", "1000"))
max_validity_scan = int(os.environ.get("FUZZ_STATUS_MAX_VALIDITY_SCAN", "1000"))

if not packet_path.is_file():
    print("target_meta unavailable")
    sys.exit(0)

packet = json.loads(packet_path.read_text(encoding="utf-8"))
lane = packet.get("lane", {})
runtime = packet.get("runtime", {})
sample = lane.get("sample_diversity", {})

lane_type = lane.get("lane_type", "unknown")
family = lane.get("family", runtime.get("component", "unknown"))
input_model = lane.get("input_model", "unknown")
strategy = sample.get("strategy", "unknown")
sync_strategy = sample.get("sync_strategy", "unknown")
seed_clusters = len(lane.get("seed_clusters", []))
successor = lane.get("successor_lane", "")
corpus_dir = pathlib.Path(runtime.get("corpus_dir", ""))
corpus_files = 0
valid_count = 0
validity_pattern = sample.get("validity_pattern", "")
noise_count = 0
validity_scanned = 0
corpus_truncated = False

if deep_scan and corpus_dir.is_dir():
    for path in corpus_dir.rglob("*"):
        if not path.is_file():
            continue
        corpus_files += 1
        if corpus_files >= max_corpus_scan:
            corpus_truncated = True
            break
        if validity_pattern and validity_scanned < max_validity_scan:
            validity_scanned += 1
            try:
                if validity_pattern in path.read_text(encoding="utf-8", errors="ignore"):
                    valid_count += 1
            except OSError:
                pass

def tail_lines(path: pathlib.Path, max_lines: int = 400, max_bytes: int = 262144):
    size = path.stat().st_size
    with path.open("rb") as f:
        f.seek(max(0, size - max_bytes))
        data = f.read()
    return data.decode("utf-8", errors="replace").splitlines()[-max_lines:]

if log_path.is_file():
    lines = tail_lines(log_path)
    for pattern in sample.get("noise_patterns", []):
        noise_count += sum(1 for line in lines if pattern in line)

parts = [
    f"mode {lane_type}",
    f"area {family}",
    f"input {input_model}",
    f"seed_groups {seed_clusters}",
    f"method {strategy}/{sync_strategy}",
]
if deep_scan:
    parts.append(f"corpus_files {'>=' if corpus_truncated else ''}{corpus_files}")
elif corpus_dir:
    parts.append("corpus_scan skipped")
if validity_pattern:
    if deep_scan:
        if validity_scanned and validity_scanned < corpus_files:
            parts.append(f"valid_sample {valid_count}/{validity_scanned}")
        else:
            parts.append(f"valid {valid_count}/{corpus_files}")
    else:
        parts.append("valid_sample skipped")
if noise_count:
    parts.append(f"recent_noise {noise_count}")
if successor:
    parts.append(f"next {successor}")

print(" | ".join(parts))
PY
}

running_proc_line_for() {
  local fuzzer="$1"
  printf '%s\n' "$process_snapshot" | grep -F "/${fuzzer} " | head -n 1 || true
}

running_root_count_for() {
  local fuzzer="$1"
  printf '%s\n' "$process_snapshot" |
    awk -v target="$fuzzer" '
      /run_libfuzzer_target[.]sh/ && index($0, "--target " target) { count++ }
      END { print count + 0 }
    '
}

state_for() {
  local proc_line="$1"
  local exit_code="$2"

  if [[ -n "$proc_line" ]]; then
    printf '%s\n' "running"
  elif [[ -z "$exit_code" ]]; then
    printf '%s\n' "stopped"
  elif [[ "$exit_code" == "0" ]]; then
    printf '%s\n' "completed"
  elif [[ "$exit_code" == "137" ]]; then
    printf '%s\n' "killed"
  else
    printf '%s\n' "exited"
  fi
}

stats_for() {
  local state="$1"
  local exit_code="$2"
  local max_total_time="$3"
  local log_summary="$4"

  case "$state" in
    running)
      printf '%s\n' "$log_summary"
      ;;
    completed)
      if [[ -n "$max_total_time" ]]; then
        printf 'exit 0 | max_total_time %ss | %s\n' "$max_total_time" "$log_summary"
      else
        printf 'exit 0 | %s\n' "$log_summary"
      fi
      ;;
    killed)
      printf 'exit %s | inferred SIGKILL/external kill | %s\n' "$exit_code" "$log_summary"
      ;;
    exited)
      printf 'exit %s | %s\n' "$exit_code" "$log_summary"
      ;;
    stale-killed)
      printf 'stale exit %s | inferred old SIGKILL/external kill | %s\n' "$exit_code" "$log_summary"
      ;;
    stale-exited)
      printf 'stale exit %s | %s\n' "$exit_code" "$log_summary"
      ;;
    stale-completed)
      printf 'stale exit 0 | %s\n' "$log_summary"
      ;;
    stale-stopped)
      printf 'stale stopped | %s\n' "$log_summary"
      ;;
    *)
      printf '%s\n' "$log_summary"
      ;;
  esac
}

build_status_line() {
  local fuzzer="$1"
  local log_file=""
  local packet_file=""
  local proc_line=""
  local state=""
  local exit_code=""
  local max_total_time=""
  local log_summary=""
  local lane_summary=""
  local binary_path=""
  local binary_summary=""
  local root_count="0"
  local duplicate_note=""
  local log_mtime="-"
  local pid="-"
  local etime="-"
  local rss_mb="-"
  local artifact_summary=""

  log_file="$(latest_log_for "$fuzzer")"
  packet_file="$(latest_lane_packet_for "$fuzzer")"
  proc_line="$(running_proc_line_for "$fuzzer")"
  root_count="$(running_root_count_for "$fuzzer")"
  exit_code="$(latest_exit_code_for "$fuzzer")"
  max_total_time="$(latest_max_total_time_for "$fuzzer")"
  binary_path="$(latest_binary_for "$fuzzer")"
  binary_summary="$(binary_evidence_summary_for "$binary_path")"
  state="$(state_for "$proc_line" "$exit_code")"
  artifact_summary="$(artifact_summary_for "$fuzzer")"

  if [[ "$state" != "running" && -f "$log_file" && "$STALE_STOPPED_SESSION_SECS" =~ ^[0-9]+$ ]]; then
    log_age=$(( $(date +%s) - $(file_mtime_epoch "$log_file") ))
    if (( log_age > STALE_STOPPED_SESSION_SECS )); then
      state="stale-$state"
    fi
  fi

  if [[ "$root_count" =~ ^[0-9]+$ && "$root_count" -gt 1 ]]; then
    duplicate_note=" | duplicate_roots=$root_count"
  fi

  if [[ -n "$proc_line" ]]; then
    pid="$(printf '%s\n' "$proc_line" | awk '{print $1}')"
    etime="$(printf '%s\n' "$proc_line" | awk '{print $2}')"
    rss_mb="$(printf '%s\n' "$proc_line" | awk '{printf "%.0f", $3/1024}')"
  fi

  if [[ -f "$log_file" ]]; then
    log_mtime="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$log_file" 2>/dev/null || echo '-')"
  fi

  log_summary="$(latest_log_summary_for "$log_file")"
  lane_summary="$(lane_diversity_summary_for "$fuzzer" "$packet_file" "$log_file")"

  printf -- '- %s\n' "$fuzzer"
  printf '  state: %s | pid: %s | up: %s | proc_rss: %sMB | artifacts: %s | log: %s%s\n' \
    "$state" "$pid" "$etime" "$rss_mb" "$artifact_summary" "$log_mtime" "$duplicate_note"
  printf '  evidence: %s\n' "$binary_summary"
  printf '  focus: %s\n' "$lane_summary"
  printf '  stats: %s\n' "$(stats_for "$state" "$exit_code" "$max_total_time" "$log_summary")"
}

build_job_status_line() {
  local name="$1"
  local process_pattern="$2"
  local note_file="$3"
  local binary_path="$4"
  local proc_line=""
  local pid="-"
  local etime="-"
  local rss_mb="-"
  local summary="no note yet"

  proc_line="$(printf '%s\n' "$process_snapshot" | grep -F "$process_pattern" | head -n 1 || true)"
  if [[ -n "$proc_line" ]]; then
    pid="$(printf '%s\n' "$proc_line" | awk '{print $1}')"
    etime="$(printf '%s\n' "$proc_line" | awk '{print $2}')"
    rss_mb="$(printf '%s\n' "$proc_line" | awk '{printf "%.0f", $3/1024}')"
  fi

  if [[ -f "$note_file" ]]; then
    summary="$("$PYTHON_BIN" - "$note_file" "$binary_path" <<'PY'
import pathlib
import sys

note = pathlib.Path(sys.argv[1])
binary = pathlib.Path(sys.argv[2])
lines = note.read_text(encoding="utf-8", errors="replace").splitlines()
fields = {}
for line in lines:
    if not line.startswith("- ") or ":" not in line:
        continue
    key, value = line[2:].split(":", 1)
    fields[key.strip()] = value.strip()
state = fields.get("state", "-")
phase = fields.get("phase", "-")
progress = fields.get("progress", "-")
current_step = fields.get("current_step", "-")
total_steps = fields.get("total_steps", "-")
load_1m = fields.get("load_1m", "-")
last_exit_code = fields.get("last_exit_code", "-")
binary_state = "present" if binary.exists() else "missing"
parts = [f"state {state}"]
if last_exit_code != "-":
    parts.append(f"last_exit {last_exit_code}")
if phase != "-":
    parts.append(f"phase {phase}")
if current_step != "-" or total_steps != "-":
    parts.append(f"steps {current_step}/{total_steps}")
if progress != "-":
    parts.append(f"progress {progress}")
if load_1m != "-":
    parts.append(f"load_1m {load_1m}")
parts.append(f"binary {binary_state}")
print(" | ".join(parts))
PY
)"
  fi

  printf -- '- %s\n' "$name"
  printf '  state: %s | pid: %s | up: %s | proc_rss: %sMB\n' \
    "$([[ -n "$proc_line" ]] && echo running || echo stopped)" "$pid" "$etime" "$rss_mb"
  printf '  stats: %s\n' "$summary"
}

printf 'Chromium fuzz status %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf '\n'
for fuzzer in "${FUZZERS[@]}"; do
  build_status_line "$fuzzer"
done
printf '\n'
printf 'Build jobs\n'
build_job_status_line \
  "indexeddb_stateful_build" \
  "/Users/bugclaw/.openclaw/workspace/chromium-vrp/fuzz/run_indexeddb_stateful_build.sh" \
  "/Users/bugclaw/.openclaw/workspace/chromium-vrp/fuzz/managed/plans/indexeddb_stateful_sequence/current/BUILD_PROGRESS.md" \
  "$INDEXEDDB_STATEFUL_BINARY"
build_job_status_line \
  "indexeddb_stateful_promote" \
  "/Users/bugclaw/.openclaw/workspace/chromium-vrp/fuzz/run_indexeddb_stateful_promote.sh" \
  "/Users/bugclaw/.openclaw/workspace/chromium-vrp/fuzz/managed/plans/indexeddb_stateful_sequence/current/PROMOTION_STATUS.md" \
  "$INDEXEDDB_STATEFUL_BINARY"
