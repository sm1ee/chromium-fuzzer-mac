#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/bugclaw/.openclaw/workspace/chromium-vrp"
SRC="$ROOT/src"
OUT="$SRC/out/libfuzzer-trend"
LLVM_BIN="$SRC/third_party/llvm-build/Release+Asserts/bin"
LOG_DIR="$ROOT/fuzz/logs"
CORPUS_DIR="$ROOT/fuzz/corpus"
WAIT_SECS="${WAIT_SECS:-60}"
WAIT_FOR_BINARY_TIMEOUT_SECS="${WAIT_FOR_BINARY_TIMEOUT_SECS:-1800}"
RUN_NICE_LEVEL="${RUN_NICE_LEVEL:-10}"

export HOME="$ROOT/.home"
export XDG_CACHE_HOME="$ROOT/.cache"
export PATH="$LLVM_BIN:$PATH"
export ASAN_OPTIONS="${ASAN_OPTIONS:-symbolize=1:external_symbolizer_path=$LLVM_BIN/llvm-symbolizer:detect_odr_violation=0:handle_segv=1}"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-symbolize=1:external_symbolizer_path=$LLVM_BIN/llvm-symbolizer:handle_segv=1}"

mkdir -p "$LOG_DIR" \
         "$CORPUS_DIR/v8_script_parser" \
         "$CORPUS_DIR/angle_translator" \
         "$CORPUS_DIR/tint_wgsl" \
         "$CORPUS_DIR/webcodecs_video_decoder" \
         "$CORPUS_DIR/css_parser_fast_paths" \
         "$CORPUS_DIR/stylesheet_contents" \
         "$CORPUS_DIR/skia_path"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

wait_for_binary() {
  local bin="$1"
  local started_at now elapsed
  started_at="$(date +%s)"
  while [[ ! -x "$bin" ]]; do
    local sleep_for="$WAIT_SECS"
    if (( WAIT_FOR_BINARY_TIMEOUT_SECS > 0 )); then
      now="$(date +%s)"
      elapsed=$((now - started_at))
      if (( elapsed >= WAIT_FOR_BINARY_TIMEOUT_SECS )); then
        log "binary wait timed out after ${elapsed}s: $bin"
        return 1
      fi
      local remaining=$((WAIT_FOR_BINARY_TIMEOUT_SECS - elapsed))
      if (( remaining < sleep_for )); then
        sleep_for="$remaining"
      fi
    fi
    log "waiting for $(basename "$bin")"
    (( sleep_for < 1 )) && sleep_for=1
    sleep "$sleep_for"
  done
}

run_fuzzer() {
  local name="$1"
  local corpus="$2"
  local max_total_time="$3"
  local rss_limit_mb="$4"
  shift 4

  local bin="$OUT/$name"
  local log_file="$LOG_DIR/${name}.log"
  local artifact_dir="$LOG_DIR/artifacts/$name"
  mkdir -p "$artifact_dir"

  if ! wait_for_binary "$bin"; then
    log "skipping $name"
    return 0
  fi
  log "starting $name"

  nice -n "$RUN_NICE_LEVEL" "$bin" \
    "$corpus" \
    -print_final_stats=1 \
    -print_pcs=1 \
    -max_total_time="$max_total_time" \
    -timeout=25 \
    -rss_limit_mb="$rss_limit_mb" \
    -artifact_prefix="$artifact_dir/" \
    "$@" >>"$log_file" 2>&1 || log "fuzzer $name exited with rc=$?"
}

run_fuzzer "v8_script_parser_fuzzer" "$CORPUS_DIR/v8_script_parser" 7200 6144 "-max_len=4096"
run_fuzzer "angle_translator_fuzzer" "$CORPUS_DIR/angle_translator" 5400 4096 "-max_len=4096"
run_fuzzer "tint_wgsl_fuzzer" "$CORPUS_DIR/tint_wgsl" 5400 4096 "-max_len=8192"
run_fuzzer "webcodecs_video_decoder_fuzzer" "$CORPUS_DIR/webcodecs_video_decoder" 5400 4096
run_fuzzer "css_parser_fast_paths_fuzzer" "$CORPUS_DIR/css_parser_fast_paths" 3600 3072
run_fuzzer "stylesheet_contents_fuzzer" "$CORPUS_DIR/stylesheet_contents" 3600 3072 "-max_len=2048"
run_fuzzer "skia_path_fuzzer" "$CORPUS_DIR/skia_path" 3600 3072
