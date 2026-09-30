# Refinement verification

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

MLX requires Xcode's Metal Toolchain. Install it through Xcode or
`xcodebuild -downloadComponent MetalToolchain`. On the first package build,
review and approve the pinned MLX package plugin and macro in Xcode. For a
trusted checkout, command-line builds can instead pass
`-skipPackagePluginValidation -skipMacroValidation`.

## Optional real-model tests

The integration tests skip when fixtures are absent. They never download
weights or use the user's model cache. Download the artifacts pinned in
`RefinementModelDescriptor.swift` and `MLXRefinementModelFile.swift` into:

```text
/tmp/DictaFlowRefinementFixtures/
  Qwen3-0.6B-Q4_K_M.gguf
  qwen3-0.6b-mlx-4bit/
    model.safetensors
    config.json
    tokenizer.json
    tokenizer_config.json
    special_tokens_map.json
    added_tokens.json
    model.safetensors.index.json
```

Every fixture is checksum-verified before inference. These tests use synthetic
English and Indonesian text, check nonempty output and completion, verify
MLX weight/cache release, and exercise llama wake after idle. Their two-second
idle interval keeps the tests short; the app uses 300 seconds.

For optimized inference checks, run the same command with
`-configuration Release ENABLE_TESTABILITY=YES`.

## Installed-app checks

Use the Dev app in `/Applications`, with its separate Dev preferences and
permissions. Check the Refinement and Models pages at the minimum window size,
with both backend switch positions and both downloaded/missing states. The
single model card should remain readable, download progress should be
continuous, and switches should lock during recording or inference.

Enabling refinement and launching the app must not load a model. Starting a
recording should prepare it in the background. A short recording should wait
for preparation before refinement. Verify raw-text fallback when startup or
inference fails. After five minutes without refinement activity, weights should
be released. Disabling refinement and quitting must leave no owned server.

The MLX switch changes the selected artifact without turning refinement off.
If that artifact is missing, dictation temporarily uses the original transcript
and the page explains the required download. Switching back restores the
standard artifact. Old downloads remain visible in Storage for explicit cleanup.

## Completed verification

The Debug suite passed all 15 tests, including the three recording startup
regressions and both optional real-model tests.
An optimized Release run also passed the lifecycle and inference checks.

The installed Dev app was checked at its minimum window size. Both backends
recorded synthetic speech, refined the transcript, and inserted the result into
a new TextEdit document. The Refinement page was checked with missing,
downloading, cancelled, and downloaded artifacts. Cancelling a download now
returns to the normal Download state without showing a failure. The Models page
keeps legacy downloads visible as unused files for explicit cleanup.

With the app's normal 300-second limit, the standard server reported
`is_sleeping: true` after five minutes. Resident memory fell from about 908 MiB
to 86 MiB. Disabling refinement removed the owned process. Quitting with loaded
weights removed both the app and its server. Relaunching with refinement still
enabled started no server; the app used about 103 MiB before recording.

The original refinement-off and recording-audio settings were restored after
testing. Both new model artifacts remain downloaded, and standard inference is
selected. The synthetic TextEdit document was left unsaved.

The recording-startup fix was also checked in the updated installed Dev app
with “Lower” recording audio enabled. Rapid clicks started a visible recording;
cancelling returned to idle, and another recording started and cancelled
normally. Controlled delays in the automated tests exercise the startup race
more precisely than the manual click check. Paste target behavior was not
changed by this fix.

These checks use short synthetic inputs. They do not establish accuracy across
long dictations or measure battery savings.

## Initial measurements, 2026-09-30

These are smoke checks on an Apple M2 Pro connected to AC power, not a benchmark
or evidence of battery-life gains. Two short synthetic transcripts were used.
First-generation timings include initial GPU work. The formats use different
4-bit quantization schemes, so this is not a controlled backend comparison.

| Check | Standard llama | Experimental MLX |
| --- | --- | --- |
| Optimized cold preparation | 9.01 s | 0.48 s |
| First generation | 0.13 s | 1.31 s |
| Second generation | 0.10 s | 0.18 s |
| Preparation after llama idle sleep | 0.38 s | Not measured |
| Idle release | 927 MiB to 106 MiB resident memory | Active weights and cache each below 10 MB above baseline |

A repeat with OS/GPU caches already warm reduced preparation to 0.54 s for
llama and 0.47 s for MLX; generation ranged from 0.12 to 0.17 s. This variation
is another reason to keep the backend experimental and measure repeated runs.

A separate server check confirmed `/props.is_sleeping`, zero-output wake, and
resident memory release. Sleeping accumulated about 0.02 CPU seconds over a
five-second interval. This is too short to estimate energy consumption.

## Comparing energy and quality

Keep standard inference as the default while testing MLX. Use the same app
build, prompt, audio fixtures, output limits, device, power mode, and background
workload. Run several repetitions in alternating backend order. Record cold
preparation, first and subsequent refinement latency, output length, idle CPU,
resident memory, and CPU/GPU power. Logs in the `Refinement` category contain
durations and token counts without transcript contents.

Compare three intervals: refinement disabled, frequent dictation with a warm
model, and at least six minutes idle after dictation. Use Instruments' energy
and processor tools, or `sudo powermetrics` with the samplers supported by that
Mac. The implementation run could not collect power data because administrator
authentication was unavailable.

Separately review names, dates, numbers, URLs, commands, lists, self-corrections,
and Indonesian language preservation across a larger fixture set. Small models
can change meaning even when the response completes. The current automated
checks detect truncation and template leakage; they do not establish cleanup
quality or semantic equivalence. CPU-thread and polling changes remain deferred
until a controlled measurement supports them.
