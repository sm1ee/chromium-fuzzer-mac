# M1 Max current-tree worker

This profile is the canonical configuration for `smlee@mac.server`.

- Source checkout: `/Users/smlee/chromium-worker/src`
- ASAN/libFuzzer output: `out/fuzz-asan-mac-arm64`
- Live operations: `/Users/smlee/chromium-worker-ops`
- Runtime data: `/Users/smlee/chromium-fuzz-data`
- Xcode: `/Users/smlee/Applications/Xcode.app`
- Initial target: `media_h264_decoder_fuzzer`

The source and dependency repositories must be clean and pinned to the
attested HEAD. A stale or mismatched checkout/binary, an unattested operations
deployment, a non-arm64 host, or a missing Metal Toolchain forces
`support_only=1` and `detection_kpi_eligible=0`.

The worker repository is read-only operationally: `sync-repo.sh` may fetch and
fast-forward `main`, but it never creates commits or pushes. Corpus, logs,
crashes, and state are kept outside Git. A sanitizer artifact is preserved for
human triage and is never auto-promoted.

Discord notifications use the same bot/channel model as the other workers.
The bot token must exist outside Git at
`/Users/smlee/chromium-fuzz-data/secrets/discord_bug_claw_bot_token` with mode
`600` or `400`. `com.bugclaw.chromium-worker-discord-artifacts` checks every
five minutes and sends only attested current-tree crash artifacts. Each real
crash-like artifact gets a local triage bundle containing the input, manifest,
metadata, sanitizer excerpt, and an archive of the original session logs.
Timeout, slow-unit, and OOM artifacts stay out of the crash feed.

`com.bugclaw.chromium-worker-watchdog` checks every five minutes and remains
silent while healthy. It alerts on launchd/coordinator loss, persistent worker
loss, stale logs, provenance failure, low disk, or an active Discord guard;
alerts are deduplicated per condition family for six hours and include a
recovery message. `com.bugclaw.chromium-worker-discord-status` posts the normal
status digest every six hours with execution rate, coverage/features, log age,
disk, separated crash/noise counts, and seed admission state.

## Seed admission

The M4 is the routing/control plane. It sends only schema-checked metadata
packets for strict media/H.264 issue-corpus records or fresh fixes. The M1 keeps
the corpus and performs the data-plane work:

1. select an already admitted H.264 corpus unit;
2. derive four deterministic, bounded NAL mutations (maximum 4096 bytes);
3. run each candidate once with the current attested ASAN fuzzer binary;
4. atomically admit clean candidates, quarantine rejects, and write a ledger.

Packets never enable automatic vulnerability promotion. Invalid packets,
non-current provenance, runtime sanitizer signals, and nonzero validation
results fail closed.
