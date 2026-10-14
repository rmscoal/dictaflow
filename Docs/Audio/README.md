# Microphone capture and audio output

DictaFlow currently uses `AVAudioRecorder` to write a local mono AAC recording
at 44.1 kHz. This document explains that choice and the AUHAL option we may
evaluate later. The goal is responsive recording without unintended changes to
other apps' playback.

## Current design

`SystemAudioRecorderService` exposes the recording lifecycle to the app
coordinator. `RecordingAudioWorker` owns the recorder on a serial background
queue so preparation, hardware start/stop, and file finalization do not block
the UI. A lock-protected status snapshot carries meter values and capture errors
back to the coordinator.

- Launch and microphone permission approval do not prepare microphone I/O.
  Launch may cache sound-cue players, without playing them.
- A recording request prepares a fresh recorder after microphone permission is
  granted. Capture starts before the start cue plays.
- Finish, cancel, preparation failure, and shutdown release recorder resources.
  Completed files are handed to the existing transcription/history flow;
  cancelled and failed captures are removed.
- Sound cues use separate `AVAudioPlayer` instances. Microphone audio is never
  connected to speaker playback.
- **System audio: Unchanged** avoids intentional volume lowering.
  **Lower** remains an explicit recording preference with volume restoration.

No Voice Processing I/O or native echo cancellation is enabled. The previous
voice-processing engine requested ducking even when it was only being prepared
at launch. Its minimum ducking level still reduced other apps' audio. Keeping
that engine prepared while idle caused the original playback problem.

Speaker playback, including a start cue, can now reach the microphone. Use
headphones or disable cues if this affects transcription. Bluetooth microphone
activation can also change playback quality through macOS's hands-free profile,
independently of app-level ducking. See
[Apple's Bluetooth explanation](https://support.apple.com/en-us/102217).

## Why AVAudioRecorder was selected

The app currently needs a completed audio file for local transcription.
`AVAudioRecorder` includes file encoding and recording-level metering, which
avoids maintaining our own production buffer pool and AAC writer.

The installed Debug Dev app produced these observations on the built-in
microphone/speaker route on 13 October 2026, with history enabled:

| Capture approach | First recording | Repeated recording | Native ducking |
| --- | --- | --- | --- |
| Voice-processing AVAudioEngine, recreated per capture | 2,265 ms | 2,126 ms | Observed |
| Input-only AVAudioEngine, recreated per capture | 184 ms | 120 ms | None observed |
| AVAudioRecorder on a background queue | 149 ms | 88 ms | None observed |

These measure the recording request to the capture API reporting ready, not
arrival of the first microphone sample, audible cue latency, or transcription.
They are observations on one route, not guaranteed latency on every device.
Recorder release took about 6 ms in the installed app.

The recorder was the fastest option tested. **Direct AUHAL capture has not been
implemented or benchmarked**, so these results do not establish that the
recorder is faster than AUHAL. Apple's internal recorder implementation is not
assumed to use any particular Audio Unit configuration.

## AUHAL as a future candidate

HAL means Hardware Abstraction Layer. It gives apps a common interface to audio
devices without writing separate code for each device's driver. AUHAL is Apple's
HAL Output Audio Unit. Despite its name, it supports microphone capture as well
as speaker output. An app can enable input and disable output.

AUHAL supplies raw audio buffers and gives us more control over device selection,
buffer delivery, and processing. We would own buffer handoff, sample conversion,
file encoding, metering, device-change handling, and cleanup. It is a lower-level
abstraction than the recorder, but that alone does not guarantee faster startup
or prevent Bluetooth profile changes.

### How to evaluate it later

Implement an input-only candidate behind `AudioRecorderServiceProtocol`, keeping
the existing coordinator, permission flow, local files, and history behavior.
Enable input bus 1 and disable output bus 0. Keep file I/O and encoding out of
the audio callback, and preserve private directories and file permissions.

Compare it against the current recorder on the same hardware and configuration:

1. Measure both request-to-ready and request-to-first-sample latency, including
   the first capture, repeated captures, and the first capture after idle.
2. Listen with continuous playback and inspect Core Audio ducking logs. Check
   output device, sample rate, and volume during launch, idle, and capture.
3. Verify real decoded audio, first/final word preservation, short recordings,
   cue leakage, and speech while speaker playback is active.
4. Exercise cancellation during preparation and capture, rapid toggles,
   preparation/encoding failures, device changes, and shutdown. Confirm input
   stops and temporary files are handled correctly.
5. Repeat on built-in devices, wired/USB devices, and Bluetooth where available.

Keep the current recorder unless the candidate shows a useful measured benefit
without output regressions or reduced recording reliability. Do not keep active
microphone I/O open while idle just to improve startup numbers.

## Verification and references

See [the test README](../../Tests/README.md) for regression tests, opt-in hardware
checks, and installed-app checks. Property snapshots alone cannot detect
per-client ducking; logs and listening checks are also needed. See
[sound-cue documentation](../../Prototypes/AudioCues/README.md) for cue behavior
and synthetic playback checks.

- [Apple: AVAudioRecorder](https://developer.apple.com/documentation/avfaudio/avaudiorecorder)
- [Apple: device input using AUHAL](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)
- [Apple: voice-processing updates and ducking](https://developer.apple.com/videos/play/wwdc2023/10235/)
