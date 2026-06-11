#!/usr/bin/env bash
set -euo pipefail

# Log rotation for fuzzer logs.
# Truncates log files exceeding MAX_LOG_SIZE_MB (default 100MB).
# Keeps a single .1 backup before truncation.
# Run via cron or launchd every hour.

LOG_DIR="${LOG_DIR:-/Users/bugclaw/.openclaw/workspace/chromium-vrp/fuzz/logs}"
MAX_LOG_SIZE_MB="${MAX_LOG_SIZE_MB:-100}"
MAX_LOG_SIZE_BYTES=$((MAX_LOG_SIZE_MB * 1024 * 1024))
MANAGED_LOG_DIR="${MANAGED_LOG_DIR:-/Users/bugclaw/.openclaw/workspace/chromium-vrp/fuzz/managed/launcher-logs}"

rotate_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0

  while IFS= read -r logfile; do
    [[ -f "$logfile" ]] || continue
    local size
    size="$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null || echo 0)"
    if (( size > MAX_LOG_SIZE_BYTES )); then
      # Keep tail (last 10MB) as .1 backup, then truncate
      tail -c $((10 * 1024 * 1024)) "$logfile" > "${logfile}.1" 2>/dev/null || true
      if command -v truncate >/dev/null 2>&1; then
        truncate -s 0 "$logfile"
      else
        : > "$logfile"
      fi
      echo "[rotate_logs] truncated $logfile (was ${size} bytes)"
    fi
  done < <(find "$dir" -maxdepth 1 -name '*.log' -type f 2>/dev/null)
}

rotate_dir "$LOG_DIR"
rotate_dir "$MANAGED_LOG_DIR"
