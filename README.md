# chromium-fuzzer-mac

Mac fuzzer fleet infrastructure. Mirrors running launchd jobs and their scripts.

## Structure

```
plists/        launchd plist definitions (active + managed)
scripts/       fuzzer runner and support scripts
lib/           shared library scripts (run_libfuzzer_target.sh, run_fuzztest_target.sh, etc.)
dicts/         fuzzer dictionaries
generators/    corpus generators (WasmGC sandbox boundary — Linux-only target)
lane_registry.json   managed lane configuration
```

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

## Build path

Binaries expected at `~/.openclaw/workspace/chromium-vrp/src/out/libfuzzer-trend/`