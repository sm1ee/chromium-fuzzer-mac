# chromium-fuzzer-mac

Mac fuzzer fleet infrastructure. The repository contains both the legacy M4
fleet snapshot and the self-contained M1 Max current-tree worker profile.

## Structure

```
plists/        launchd plist definitions (active + managed)
scripts/       fuzzer runner and support scripts
lib/           shared library scripts (run_libfuzzer_target.sh, run_fuzztest_target.sh, etc.)
dicts/         fuzzer dictionaries
generators/    corpus generators (WasmGC sandbox boundary — Linux-only target)
lane_registry.json   managed lane configuration
m1-worker/           M1 Max canonical source, deploy/sync, provenance, launchd
```

## M1 Max worker

The M1 host is deliberately separate from the legacy `/Users/bugclaw/...`
layout. Its canonical repository is `/Users/smlee/chromium-fuzzer-mac`, while
the checkout, deployed operations files, and runtime data stay outside Git:

```
~/chromium-fuzzer-mac/   canonical Git checkout; fetch/fast-forward only
~/chromium-worker/src/   clean Chromium checkout
~/chromium-worker-ops/   verified deployment of m1-worker files
~/chromium-fuzz-data/    corpus, artifacts, logs, state, metrics
```

`m1-worker/bin/sync-repo.sh` follows the Windows/Linux self-contained-host
model: it accepts only a clean, linear `origin/main` state, validates every
deployed shell/plist file, atomically replaces the live operations directory,
and records the exact repository HEAD. It never commits or pushes from the
worker. Runtime results are never copied into Git.

Initial deployment on the M1:

```bash
git clone https://github.com/sm1ee/chromium-fuzzer-mac.git ~/chromium-fuzzer-mac
~/chromium-fuzzer-mac/m1-worker/bin/install-launchagents.sh
```

The installer only copies LaunchAgents by default. Pass `--load` after a
successful current-tree build and 60-second smoke run. The initial M1 lane is
`media_h264_decoder_fuzzer`; additional macOS/Metal lanes must pass the same
provenance and smoke gates before being loaded.

## Active Fleet (10 launchd jobs)

| Job | Script | Target |
|-----|--------|--------|
| angle-translator | lib/run_libfuzzer_target.sh | angle_translator_fuzzer |
| audio-processing | lib/run_libfuzzer_target.sh | audio_processing_fuzzer |
| webcodecs | lib/run_libfuzzer_target.sh | webcodecs_video_decoder_fuzzer |
| indexeddb | lib/run_libfuzzer_target.sh | indexed_db_leveldb_coding_decodeidbkey_fuzzer |
| indexeddb-stateful | lib/run_fuzztest_target.sh | IndexedDbCodingStatefulSequence |
| v8-semantic | scripts/run_v8_semantic_fuzz.sh | custom v8 semantic |
| graphics-precision | scripts/run_graphics_precision_fuzz.sh | custom graphics |
| artifact-notifier | scripts/run_artifact_notifier_batch.sh | triage pipeline |
| status-batch | scripts/run_fuzz_status_batch.sh | fleet status |
| recover | scripts/recover_main_fuzzing_stack.sh | watchdog |

## Launchd duplicate guard

The local machine may have both legacy labels in `~/Library/LaunchAgents` and recovered managed labels bootstrapped from `~/.openclaw/workspace/chromium-vrp/fuzz/launchagents/`. The recover script now avoids bootstrapping a managed lane when the equivalent legacy lane is already loaded, unless `ALLOW_MAC_FUZZ_DUPLICATE=1` is set. `status_managed_fuzzers.sh` prints `duplicate_roots=N` when multiple `run_libfuzzer_target.sh` roots are still active for the same target.

## Legacy M4 build path

Binaries expected at `~/.openclaw/workspace/chromium-vrp/src/out/libfuzzer-trend/`
