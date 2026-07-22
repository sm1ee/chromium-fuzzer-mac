#!/bin/bash
set -euo pipefail

OPS_ROOT="/Users/smlee/chromium-worker-ops"
# shellcheck source=/dev/null
source "$OPS_ROOT/config/worker.env"

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <channel-id> <payload-json-file>" >&2
    exit 64
fi
channel_id="$1"
payload_file="$2"
if [[ ! "$channel_id" =~ ^[0-9]+$ ]]; then
    echo "invalid Discord channel id" >&2
    exit 64
fi
if [ ! -s "$payload_file" ] || ! /usr/bin/jq -e . "$payload_file" >/dev/null; then
    echo "invalid Discord payload file" >&2
    exit 65
fi
if [ ! -s "$DISCORD_TOKEN_FILE" ]; then
    echo "missing Discord bot token: $DISCORD_TOKEN_FILE" >&2
    exit 66
fi
token_mode="$(/usr/bin/stat -f '%Lp' "$DISCORD_TOKEN_FILE")"
if [ "$token_mode" != "600" ] && [ "$token_mode" != "400" ]; then
    echo "unsafe Discord bot token mode: $token_mode" >&2
    exit 67
fi
if [ "${DISCORD_DRY_RUN:-0}" = "1" ]; then
    echo "discord_dry_run channel=$channel_id"
    exit 0
fi

token="$(/usr/bin/head -n 1 "$DISCORD_TOKEN_FILE" | /usr/bin/tr -d '\r\n')"
if [ -z "$token" ]; then
    echo "empty Discord bot token: $DISCORD_TOKEN_FILE" >&2
    exit 66
fi
/bin/mkdir -p "$DATA_ROOT/state"
guard_file="$DATA_ROOT/state/discord-rest-guard.tsv"
token_fingerprint="$(/usr/bin/shasum -a 256 "$DISCORD_TOKEN_FILE" | /usr/bin/awk '{print $1}')"
now="$(/bin/date +%s)"
if [ -s "$guard_file" ]; then
    IFS=$'\t' read -r guard_until guard_reason guard_fingerprint < "$guard_file" || true
    if [[ "$guard_until" =~ ^[0-9]+$ ]] &&
       [ "$guard_fingerprint" = "$token_fingerprint" ] &&
       [ "$now" -lt "$guard_until" ]; then
        echo "Discord send skipped by local guard: reason=${guard_reason:-unknown} until_epoch=$guard_until" >&2
        exit 75
    fi
    /bin/rm -f "$guard_file"
fi
set_guard() {
    reason="$1"
    cooldown_secs="$2"
    /usr/bin/printf '%s\t%s\t%s\n' "$(( $(/bin/date +%s) + cooldown_secs ))" "$reason" "$token_fingerprint" > "$guard_file"
    /bin/chmod 600 "$guard_file"
}
response="$(/usr/bin/mktemp "$DATA_ROOT/state/discord-response.XXXXXX")"
cleanup() { /bin/rm -f "$response"; }
trap cleanup EXIT

for attempt in 1 2; do
    : > "$response"
    set +e
    status="$(/usr/bin/curl -sS --max-time 20 -o "$response" -w '%{http_code}' \
        -X POST \
        -H "Authorization: Bot $token" \
        -H "Content-Type: application/json" \
        --data-binary "@$payload_file" \
        "https://discord.com/api/v10/channels/$channel_id/messages")"
    curl_rc=$?
    set -e
    if [ "$curl_rc" -ne 0 ]; then
        status="curl_failed"
    fi
    if [ "$status" = "429" ]; then
        retry_after="$(/usr/bin/jq -r '((.retry_after // 5) | tonumber | ceil) + 1' "$response" 2>/dev/null || echo 10)"
        if ! [[ "$retry_after" =~ ^[0-9]+$ ]]; then retry_after=10; fi
        if [ "$retry_after" -gt 60 ]; then retry_after=60; fi
        /bin/sleep "$retry_after"
        continue
    fi
    if [[ "$status" == 2* ]]; then
        /bin/rm -f "$guard_file"
        echo "discord_sent channel=$channel_id status=$status"
        exit 0
    fi
    if [ "$status" = "401" ] || [ "$status" = "403" ]; then
        set_guard "auth_$status" 21600
    fi
    echo "Discord send failed: channel=$channel_id status=$status response=$(/usr/bin/head -c 300 "$response" | /usr/bin/tr '\n\r' '  ')" >&2
    break
done
if [ "$status" = "429" ]; then
    set_guard "rate_429" 900
fi
exit 1
