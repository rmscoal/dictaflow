# DictaFlow verification

`DictaFlowTests` is hosted by the Dev app. It checks preference migration,
startup failure, readiness retry pacing, shared preparation, shutdown during
startup, waking a sleeping server, rejection of incomplete output, verified
model storage, and download cancellation.

`RecordingStartupTests` exercises the real app coordinator with isolated
settings, silent cue playback, and synthetic recorder services. It checks
capture starting before volume lowering, restoration after an in-flight volume
change, cancellation during preparation, repeated toggles during recorder
startup, permission denial, and retry after a failed start or preparation. It also
checks that launch and microphone permission approval do not prepare the recorder
or lower system volume. These tests never
record microphone audio, play sound cues, or write to the user's clipboard.

For audio lifecycle verification, use the installed Dev app with continuous
video or music playback. Launch and idle must leave playback volume unchanged.
After stop, cancel, or failure, playback must return to its original level and
the AudioCapture logs must report recorder release. Compare first and repeated
recording readiness times on the same input/output route; each recording now
prepares a fresh recorder. Test speakers, headphones, and Bluetooth if available,
with sound cues and optional volume lowering both enabled and disabled.

`RecordingAudioStatusTests` checks stale delegate callbacks after cancellation,
unexpected stops, and encoding failures during finalization. These use no audio
hardware.

`SoundCueServiceTests` uses silent players to check delayed completion/error
callbacks after cancellation or timeout and queued requests for the same cue.
Each playback owns a separate player, so old callbacks cannot stop a newer cue.

The opt-in `RecordingAudioIntegrationTests` compares input-only AVAudioEngine
with the production AVAudioRecorder service. It verifies real AAC output,
permissions on capture files, output device/rate/master-volume preservation,
and microphone release after finish, preparation failure, and cancellation.
It records short samples in a private temporary directory, deletes them afterward,
and never transcribes or inserts them. Existing microphone permission is required;
otherwise the checks skip. Run while the input/output route and volume are stable:

```sh
python3 script/verify_audio_capture.py
```

These output-property checks cannot detect per-client ducking. Also inspect
Core Audio's ducking logs and listen with continuous playback in the installed
app. Bluetooth microphone use can change playback quality through macOS's
hands-free profile even without app-level ducking; check that route separately.

## Audio startup comparison

See [the audio capture README](../Docs/Audio/README.md) for the current design,
its tradeoffs, and a future AUHAL evaluation plan. AUHAL has not been benchmarked.

Measured in the Debug Dev app on the built-in microphone and speaker route,
13 October 2026. Times run from the recording request to the capture API reporting
ready, with history enabled. They exclude transcription and audible cue latency.

| Capture approach | First recording | Repeated recording | Native ducking |
| --- | --- | --- | --- |
| Voice-processing AVAudioEngine, recreated each time | 2,265 ms | 2,126 ms | Observed |
| Input-only AVAudioEngine, recreated each time | 184 ms | 120 ms | None observed |
| AVAudioRecorder in a background worker | 149 ms | 88 ms | None observed |

The isolated hardware comparison also favored AVAudioRecorder: 85, 18, and
16 ms including production service preparation/start, versus 83, 70, and 70 ms
for an input-only engine. Recorder release took about 6 ms in the installed app.
These are observations on one route, not guaranteed timings on every device.
The app keeps a fresh recorder per capture and preserves idle microphone privacy.
No native echo cancellation is enabled; cue leakage and speech with speaker
playback need listening/transcription checks.

`HistoryStoreTests` uses isolated SQLite databases and synthetic audio. It checks
append-only retries, refinement parents, searching earlier results, cancellation,
restart recovery, retention, active-file protection, cascading deletion, and late
completion after deletion. Coordinator checks also cover managed recording
cleanup, retries without automatic insertion, and keeping an older Whisper
result selected after refining it again.

For manual history checks, use the installed Dev app. Finish a short recording,
click its card to expand it, replay and seek it, and retry transcription. Confirm the model, task, language, and refinement setting
in the retry popover; Cancel must not start processing. Check that a completed
retry shows an attempt number and whether its text changed. Open
Previous Results from the recording's actions menu to select an earlier attempt;
its refinement must stay attached to that transcription. Selecting another card
or collapsing the current one must stop playback. Refreshing should preserve a
selected older attempt and leave collapsed cards closed. Check no-speech and failure states, and both delete confirmation
dialogs. Check narrow windows and light/dark appearance: confirmation popovers
should open toward the card, and the Original/Refined switch must not wrap its
label. Audio loading, transcription, model preparation, and refinement must show
clear progress. Escape during recording must leave no saved entry. History defaults to
7 days; Off stops new saves and 14 days extends retention from the original
recording date. Audio and every result share that expiry.
Changing retention should apply immediately when no recordings exceed the new
limit. Otherwise, confirmation must show the affected count; cancelling must
leave retention and saved recordings unchanged. This also applies after Off.

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
provider tabs and model rows should remain readable, download progress should be
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


## Multiple refinement models and writing styles

`RefinementWritingStyleTests` checks preset composition, DIY replacement, language
requirements, model preference round trips, pinned download revisions, private
prompt persistence, and corrupt/symlink storage rejection. Coordinator tests
check that unsaved drafts never reach inference and that additions stay separate
per preset. Lifecycle tests cover ordered long-transcript chunks and rejection
of the entire rewrite when a later chunk is incomplete. Context-aware fixtures
check corrections across source boundaries, continuous list numbering, and no
duplicated earlier output. Storage tests check that a failed load cannot overwrite
existing additions and that repairing the file permits a retry without restarting.

Optional real-model tests cover every model in `RefinementModelDescriptor.allCases`.
Supply their checksum-pinned filenames in `/tmp/DictaFlowRefinementFixtures/`.
These tests do not download models. A slow connection is sufficient for manual
start/progress/cancel checks, but cannot establish inference quality or RAM usage
for new weights. Verify all three provider tabs, the active-model summary, download
status across tabs, preset switching, per-preset saving, DIY Write/Preview, and
narrow-window light/dark layouts in the installed Dev app.

`testQwen3FourBPreservesIndonesianIntent` runs each Indonesian case three times
with Qwen3-4B-Instruct-2507 and Casual Text Messaging. It checks mixed construction facts
and a question, an unanswered RAB question with a request, a questionnaire, and
statements with negation and uncertainty. Supply the pinned
`Qwen3-4B-Instruct-2507-Q4_K_M.gguf` fixture to run it. Missing weights skip the
check. Term and punctuation assertions catch the reported failures but do not
prove complete semantic fidelity; review the outputs in the installed app too.

For a before/after comparison, select the same original transcript in History
and use **Refine Again** with the same model and writing style. Rebuild and
relaunch after changing built-in prompts or the source wrapper. Compare the
**Refined** view and keep earlier attempts available through Previous Results.

`testVerifiedQwenLongTranscriptQualityProbe` records an unresolved Qwen3 0.6B
limitation: it can omit a corrected date or retain the superseded date among
many repetitive technical facts. This known-failing quality probe is explicitly
excluded from normal test runs. When enabled, both date assertions and all
runtime and identifier/number checks fail normally; there are no expected failures.
Supply the pinned Qwen3 0.6B fixture and run:

```sh
TEST_RUNNER_DICTAFLOW_RUN_QUALITY_PROBES=1 xcodebuild \
  -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" \
  -configuration Debug -derivedDataPath .build/DerivedData test \
  -only-testing:DictaFlowTests/RefinementIntegrationTests/testVerifiedQwenLongTranscriptQualityProbe
```

Xcode forwards the `TEST_RUNNER_` variable to the test process as
`DICTAFLOW_RUN_QUALITY_PROBES`. A passing normal suite does not resolve this
limitation. Do not interpret passing structural chunk tests as proof that every
model preserves every fact.

## Dictation tone and combined settings

`TextToneFormatterTests` checks conservative English rules, protected structured
text and vocabulary, non-English behavior, empty output, idempotence, settings
persistence, and legacy result decoding. `RecordingStartupTests` verifies the
pipeline with refinement off, on, and failing, including the locked tone snapshot,
inserted/copied text, and retrieving the original. `HistoryStoreTests` checks raw
and final search/preview, saved rule versions, and upgrade from the v2 schema.

In the installed Dev app, check Dictation's three tabs, all six Whisper cards,
split download buttons and installed-model menus, and the existing
refinement provider/model and DIY controls. Check narrow-window layouts and
that sound cues and custom vocabulary remain below speech models. Tone preview
should update without enabling refinement. Verify download/progress/cancel and
encoder on/off with real artifacts when available.

“Download with Encoder” downloads and verifies the speech model first, then
downloads its encoder through the existing encoder path. Check cancellation in
both stages and retry after a model or encoder failure. Cancelling the model
stage must not start the encoder; an encoder failure must keep the downloaded
model. The installed-model menu offers “Download Encoder” when missing and
“Use Encoder” when installed. While an encoder downloads for an inactive,
downloaded model, “Use model” must remain available. Selecting the model must
leave the encoder downloading, and “Cancel encoder” must stop only the encoder
download. Removal must confirm and remove the model together
with its encoder, including a disabled encoder. Switch away from the active
model before removing it; keep at least one downloaded speech model.

`RecordingStartupTests` also checks combined download order, cancellation with
late completion, model failure followed by a plain retry, and encoder failure
followed by an encoder-only retry. These checks use synthetic download services
and do not download weights.

## Per-app writing styles

`RefinementStyleResolverTests` covers exact bundle-ID matching, unknown and missing
apps, the disabled toggle, DIY, moving/removing rules, preference round trips,
and one-time starter migration. Migration keeps the user's default and existing
assignments; removed starter rules are not restored on later launches.
`RecordingStartupTests.testRecordingStyleSnapshotReachesPromptAndHistory` checks
that the recording's style selects its saved instructions and reaches history,
with settings locked while recording.

In the installed Dev app, open Dictation > Refinement. Check the style-filtered
app list, inline empty state, search, multiple selection, disk picker, removal,
and Cancel/Move confirmation. Switch to a different external app and return to
DictaFlow to check the live example. Start a recording in an assigned app, switch
apps before stopping, and confirm the history style still matches the original
target. Repeat with an unassigned app and with “Switch style by app” off.

Decided behavior, not a bug: retrying from History (“Refine again” and
re-transcribe) intentionally uses the refinement configuration as it is at
retry time — the current model and the currently selected Style, which is also
the default style — instead of the effective style stored on the original
attempt. It also does not re-resolve a per-app rule, because history does not
store the app the text was dictated into (only the effective style is stored,
on each refinement attempt). So if the default Style has changed since the
recording was made, a retry can produce a differently styled result. The first
refinement of a recording is unaffected: it always uses the style snapshot
taken when recording started. This matches the general rule in the main README
that retrying creates a new result using current settings.
