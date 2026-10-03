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
