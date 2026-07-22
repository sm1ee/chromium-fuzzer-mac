#!/bin/bash
set -euo pipefail

REPO_ROOT="/Users/smlee/chromium-fuzzer-mac"
PROFILE_ROOT="$REPO_ROOT/m1-worker"
# shellcheck source=/dev/null
source "$PROFILE_ROOT/config/worker.env"

fetch=1
if [ "${1:-}" = "--no-fetch" ]; then
    fetch=0
    shift
fi
if [ "$#" -ne 0 ]; then
    echo "usage: $0 [--no-fetch]" >&2
    exit 64
fi

/bin/mkdir -p "$DATA_ROOT/state" "$DATA_ROOT/logs"
lock_dir="$DATA_ROOT/state/repo-sync.lockdir"
if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
    echo "sync already active: $lock_dir" >&2
    exit 75
fi
stage=""
backup=""
cleanup() {
    if [ -n "$stage" ] && [ -d "$stage" ]; then /bin/rm -rf "$stage"; fi
    if [ -n "$backup" ] && [ -d "$backup" ]; then
        if [ ! -e "$OPS_ROOT" ]; then
            /bin/mv "$backup" "$OPS_ROOT" ||
                echo "WARNING: previous operations directory preserved at $backup" >&2
        else
            echo "WARNING: previous operations directory preserved at $backup" >&2
        fi
    fi
    /bin/rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -d "$REPO_ROOT/.git" ]; then
    echo "canonical repository is missing: $REPO_ROOT" >&2
    exit 2
fi
branch="$(/usr/bin/git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD || true)"
if [ "$branch" != "main" ]; then
    echo "canonical repository must be on main: branch=$branch" >&2
    exit 2
fi
if [ -n "$(/usr/bin/git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]; then
    echo "canonical repository is dirty; refusing sync" >&2
    exit 3
fi

export GIT_TERMINAL_PROMPT=0
if [ "$fetch" = "1" ]; then
    /usr/bin/git -C "$REPO_ROOT" fetch --prune origin main
    head_before="$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)"
    origin_head="$(/usr/bin/git -C "$REPO_ROOT" rev-parse origin/main)"
    if [ "$head_before" != "$origin_head" ]; then
        if ! /usr/bin/git -C "$REPO_ROOT" merge-base --is-ancestor "$head_before" "$origin_head"; then
            echo "canonical repository diverged or is ahead; refusing automatic reconciliation" >&2
            exit 4
        fi
        /usr/bin/git -C "$REPO_ROOT" merge --ff-only "$origin_head"
    fi
fi

if [ -n "$(/usr/bin/git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]; then
    echo "canonical repository changed during sync" >&2
    exit 3
fi
head_value="$(/usr/bin/git -C "$REPO_ROOT" rev-parse HEAD)"

for script in "$PROFILE_ROOT"/bin/*.sh; do /bin/bash -n "$script"; done
for plist in "$PROFILE_ROOT"/launchagents/*.plist; do /usr/bin/plutil -lint "$plist" >/dev/null; done
/bin/bash -n "$PROFILE_ROOT/config/worker.env"

stage="$(/usr/bin/mktemp -d "$DATA_ROOT/state/ops-stage.XXXXXX")"
/bin/mkdir -p "$stage/bin" "$stage/config" "$stage/dicts" "$stage/launchagents"
/bin/cp "$PROFILE_ROOT"/bin/*.sh "$stage/bin/"
/bin/cp "$PROFILE_ROOT/config/worker.env" "$stage/config/worker.env"
primary_dict="$REPO_ROOT/dicts/$PRIMARY_TARGET.dict"
if [ -f "$primary_dict" ]; then /bin/cp "$primary_dict" "$stage/dicts/"; fi
/bin/cp "$PROFILE_ROOT"/launchagents/*.plist "$stage/launchagents/"
/bin/chmod 755 "$stage"/bin/*.sh
/bin/chmod 644 "$stage/config/worker.env" "$stage"/dicts/* "$stage"/launchagents/*.plist
/usr/bin/printf '%s\n' "$head_value" > "$stage/deploy-head.txt"
(
    cd "$stage"
    /usr/bin/find . -type f ! -name deploy-manifest.tsv -print | /usr/bin/sort |
        while IFS= read -r path; do
            hash="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
            /usr/bin/printf '%s  %s\n' "$hash" "${path#./}"
        done > deploy-manifest.tsv
)

for script in "$stage"/bin/*.sh; do /bin/bash -n "$script"; done
for plist in "$stage"/launchagents/*.plist; do /usr/bin/plutil -lint "$plist" >/dev/null; done

if [ -f "$OPS_ROOT/deploy-manifest.tsv" ] &&
   /usr/bin/cmp -s "$OPS_ROOT/deploy-manifest.tsv" "$stage/deploy-manifest.tsv"; then
    echo "sync_head=$head_value deploy=noop"
    exit 0
fi

if [ -d "$DATA_ROOT/state/build.lockdir" ] ||
   /usr/bin/find "$DATA_ROOT/state" -maxdepth 1 -type d -name '*.lockdir' ! -name repo-sync.lockdir | /usr/bin/grep -q .; then
    echo "sync_head=$head_value deploy=deferred active_worker_lock=1"
    exit 0
fi

backup="$DATA_ROOT/state/ops-backup.$$"
if [ -e "$backup" ]; then
    echo "unexpected backup path exists: $backup" >&2
    exit 5
fi
if [ -e "$OPS_ROOT" ]; then /bin/mv "$OPS_ROOT" "$backup"; fi
if ! /bin/mv "$stage" "$OPS_ROOT"; then
    if [ -d "$backup" ]; then /bin/mv "$backup" "$OPS_ROOT"; fi
    echo "deploy failed; previous operations directory restored" >&2
    exit 6
fi
stage=""
if [ -d "$backup" ]; then /bin/rm -rf "$backup"; fi
backup=""
echo "sync_head=$head_value deploy=updated ops_root=$OPS_ROOT"
