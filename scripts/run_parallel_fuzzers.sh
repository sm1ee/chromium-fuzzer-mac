#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
SRC="$ROOT/src"
OUT="$SRC/out/libfuzzer-trend"
LLVM_BIN="$SRC/third_party/llvm-build/Release+Asserts/bin"
LOG_DIR="$ROOT/fuzz/logs"
CORPUS_DIR="$ROOT/fuzz/corpus"

export HOME="$ROOT/.home"
export XDG_CACHE_HOME="$ROOT/.cache"
export PATH="$LLVM_BIN:$PATH"
export ASAN_OPTIONS="${ASAN_OPTIONS:-symbolize=1:external_symbolizer_path=$LLVM_BIN/llvm-symbolizer:detect_odr_violation=0:handle_segv=1}"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-symbolize=1:external_symbolizer_path=$LLVM_BIN/llvm-symbolizer:handle_segv=1}"

mkdir -p "$LOG_DIR" \
         "$LOG_DIR/artifacts/v8_script_parser_parallel" \
         "$LOG_DIR/artifacts/angle_translator" \
         "$LOG_DIR/artifacts/tint_wgsl" \
         "$LOG_DIR/artifacts/webcodecs_video_decoder" \
         "$LOG_DIR/artifacts/css_parser_fast_paths" \
         "$CORPUS_DIR/v8_script_parser" \
         "$CORPUS_DIR/angle_translator" \
         "$CORPUS_DIR/tint_wgsl" \
         "$CORPUS_DIR/webcodecs_video_decoder" \
         "$CORPUS_DIR/css_parser_fast_paths"

STARTED_PIDS=()

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

run_one() {
  local name="$1"
  local corpus="$2"
  local rss_limit_mb="$3"
  local artifact_dir="$4"
  shift 4

  local bin="$OUT/$name"
  local log_file="$LOG_DIR/${name}.log"

  if [[ ! -x "$bin" ]]; then
    log "missing binary: $bin"
    return 0
  fi

  log "starting $name"
  "$bin" \
    "$corpus" \
    -print_final_stats=1 \
    -print_pcs=1 \
    -timeout=25 \
    -rss_limit_mb="$rss_limit_mb" \
    -artifact_prefix="$artifact_dir/" \
    "$@" >>"$log_file" 2>&1 &
  local pid=$!
  STARTED_PIDS+=("$pid")
  log "started $name pid=$pid"
}

run_one "v8_script_parser_fuzzer" \
  "$CORPUS_DIR/v8_script_parser" \
  6144 \
  "$LOG_DIR/artifacts/v8_script_parser_parallel" \
  "-max_len=4096"

run_one "angle_translator_fuzzer" \
  "$CORPUS_DIR/angle_translator" \
  4096 \
  "$LOG_DIR/artifacts/angle_translator" \
  "-max_len=4096"

run_one "tint_wgsl_fuzzer" \
  "$CORPUS_DIR/tint_wgsl" \
  4096 \
  "$LOG_DIR/artifacts/tint_wgsl" \
  "-max_len=8192"

run_one "webcodecs_video_decoder_fuzzer" \
  "$CORPUS_DIR/webcodecs_video_decoder" \
  4096 \
  "$LOG_DIR/artifacts/webcodecs_video_decoder"

run_one "css_parser_fast_paths_fuzzer" \
  "$CORPUS_DIR/css_parser_fast_paths" \
  2048 \
  "$LOG_DIR/artifacts/css_parser_fast_paths"

if (( ${#STARTED_PIDS[@]} == 0 )); then
  log "no fuzzers started"
  exit 0
fi

overall=0
for pid in "${STARTED_PIDS[@]}"; do
  wait "$pid" || overall=$?
done
exit "$overall"
