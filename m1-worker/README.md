# M1 Max current-tree worker

This profile is the canonical configuration for `smlee@mac.server`.

- Source checkout: `/Users/smlee/chromium-worker/src`
- ASAN/libFuzzer output: `out/fuzz-asan-mac-arm64`
- Live operations: `/Users/smlee/chromium-worker-ops`
- Runtime data: `/Users/smlee/chromium-fuzz-data`
- Xcode: `/Users/smlee/Applications/Xcode.app`
- Initial target: `webcodecs_video_decoder_fuzzer`

The source and dependency repositories must be clean and pinned to the
attested HEAD. A stale or mismatched checkout/binary, an unattested operations
deployment, a non-arm64 host, or a missing Metal Toolchain forces
`support_only=1` and `detection_kpi_eligible=0`.

The worker repository is read-only operationally: `sync-repo.sh` may fetch and
fast-forward `main`, but it never creates commits or pushes. Corpus, logs,
crashes, and state are kept outside Git. A sanitizer artifact is preserved for
human triage and is never auto-promoted.
