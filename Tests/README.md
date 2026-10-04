# DictaFlow verification

`DictaFlowTests` is hosted by the Dev app. It checks preference migration,
startup failure, readiness retry pacing, shared preparation, shutdown during
startup, waking a sleeping server, rejection of incomplete output, verified
model storage, and download cancellation.

`RecordingStartupTests` exercises the real app coordinator with isolated
settings and synthetic recorder services. It checks repeated toggles during
audio ducking and recorder startup, stopping after startup, permission denial,
and retry after a failed start. These tests never record microphone audio or
write to the user's clipboard.

Run it with Xcode's Test action or:

```sh
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" \
  -configuration Debug -derivedDataPath .build/DerivedData test
```

## Optional real-model tests

The integration tests skip when fixtures are absent. They never download
weights or use the user's model cache. Download the artifacts pinned in
`RefinementModelDescriptor.swift` into:

```text
/tmp/DictaFlowRefinementFixtures/
  Qwen3-0.6B-Q4_K_M.gguf
```

Every fixture is checksum-verified before inference. These tests use synthetic
English and Indonesian text, check nonempty output and completion, exercise llama wake after idle. Their two-second
idle interval keeps the tests short; the app uses 300 seconds.

For optimized inference checks, run the same command with
`-configuration Release ENABLE_TESTABILITY=YES`.

## Speech detection verification

`WhisperServiceTests` checks the bundled Silero model and license, checksum
rejection and retry, missing-resource errors in transcription and translation,
and the dedicated encoder warmup path. Coordinator tests also cover skipping
refinement and insertion for empty transcripts, onboarding's no-speech result,
and using encoder warmup after an encoder download.

`WhisperIntegrationTests` uses `/tmp/DictaFlowWhisperFixtures/`. It never downloads
weights or reads the user's model cache. Supply checksum-pinned `ggml-base.bin`
or `ggml-large-v3-turbo.bin` manually; Base is preferred when both are present.
The issue #15 tests specifically require Large V3 Turbo. An invalid weight file
fails verification rather than being skipped.

The brief-word regression tests run separately with Base and Large V3 Turbo.
They require unpadded 100–250 ms pronunciations, then add leading and trailing
silence and a 500 ms pause before a longer sentence. They check complete word
preservation with automatic and fixed English, vocabulary, and translation,
followed by silence on the reused context. The app uses a 100 ms minimum speech
duration; the other vendored VAD defaults remain unchanged.

The translation check requires `ggml-large-v3.bin`. Base produced the same
incorrect translation of the synthetic Indonesian sample with and without VAD,
so Indonesian translation is checked with Large V3. The brief English phrases
are also checked in translation mode with Base and Large V3 Turbo. The optional
Core ML warmup check also requires `ggml-large-v3-turbo-encoder.mlmodelc` beside
its Whisper weights.

Audio fixtures are optional and stay outside Git:

| Fixture | Content |
| --- | --- |
| `speech-en.wav` | “Please send the report tomorrow.” |
| `thank-you-en.wav` | Legitimately spoken “Thank you.” |
| `look-en.wav` | A short, legitimately spoken “Look.” |
| `brief-no-en.wav` | Unpadded “No”, shorter than 250 ms (225 ms in the reproduced case) |
| `brief-look-en.wav` | Unpadded “Look”, shorter than 250 ms (201 ms in the reproduced case) |
| `quiet-en.wav` | The `speech-en.wav` phrase spoken quietly |
| `pauses-en.wav` | The same phrase with an internal pause |
| `speech-id.wav` | “Tolong kirim laporannya besok pagi.” |
| `translation-id.wav` | “Tolong kirim laporan itu besok pagi. Saya ingin membaca semua hasil pengujian sebelum rapat dimulai.” |
| `noise.wav` | Synthetic white noise or supplied non-speech room noise |
| `breath.wav` | Breath and room noise without speech |
| `issue15-31.5s.m4a` | The preserved affected recording from issue #15 |
| `issue15-61.6s.m4a` | The preserved control recording |
| `issue15-61.6s.txt` | The reviewed expected control transcript |

The integration tests check speech → silence → speech on one context,
unload/reload, timestamps in the original recording, short and quiet speech,
vocabulary context, Indonesian transcription and translation, and non-speech
audio. Missing fixtures are reported as skipped. Synthetic audio is useful for
repeatable checks but does not replace listening to the two original recordings.

Run only speech-detection checks with:

```sh
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" \
  -configuration Debug -derivedDataPath .build/DerivedData \
  -only-testing:DictaFlowTests/WhisperServiceTests \
  -only-testing:DictaFlowTests/WhisperIntegrationTests test
```

For installed-app acceptance, use `/Applications/DictaFlow Dev.app` offline.
Check no-speech feedback with refinement enabled and disabled, onboarding
practice, and legitimate spoken endings. After downloading a Neural Engine
encoder, verify that its silent warmup still runs. Both Dev and release bundles
must contain the pinned VAD model and Silero license. Speech detection has no
toggle or separate download. Missing or damaged bundled weights must produce
an actionable error instead of an unfiltered transcript.

## Installed-app checks

Use the Dev app in `/Applications`, with its separate Dev preferences and
permissions. Check the Refinement and Models pages at the minimum window size,
with both downloaded and missing model states. The
single model card should remain readable, download progress should be
continuous, and switches should lock during recording or inference.

Enabling refinement and launching the app must not load a model. Starting a
recording should prepare it in the background. A short recording should wait
for preparation before refinement. Verify raw-text fallback when startup or
inference fails. After five minutes without refinement activity, weights should
be released. Disabling refinement and quitting must leave no owned server.

Previous MLX preferences migrate to standard Qwen3 without disabling refinement.
Old downloads remain visible in Storage for explicit cleanup.

## Verification after MLX removal

A clean Debug build passed all 14 tests, including real standard-model inference
and idle wake, retired preference migration, storage cleanup, and recording
startup regressions. `make run` also passed without package validation bypasses.
The installed app showed standard-only refinement with the custom prompt intact.
Its signature passed verification and its bundle contained no MLX resources.
The install script's replacement and failure rollback paths passed isolated checks.

## Verification after bounded shutdown fix

All 15 tests passed, including real standard-model inference. The seven lifecycle
tests also passed five consecutive runs (35 executions). The new regression test
covers a runtime that ignores SIGTERM, concurrent shutdown requests, actual
process exit, and a successful restart.

`make run` rebuilt and installed the Dev app. Disabling refinement stopped its
loaded server; quitting with a loaded model closed both the app and server.
The installed app's signature passed verification.

## Energy and quality checks

Compare refinement disabled, frequent dictation with a warm model, and at least
six minutes idle after dictation. Use matching audio, prompts, power mode, and
background apps. Measure latency, idle CPU, resident memory, and CPU/GPU power.
Power measurements cover the whole machine and do not establish output quality.
Review questions, requests, names, numbers, self-corrections, and mixed-language
text separately for preservation of meaning.
