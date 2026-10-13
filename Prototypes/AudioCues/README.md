# DictaFlow sound cues

Two original sound sets are included in the app:

| Style | Character |
| --- | --- |
| Soft Digital | Short, rounded electronic tones. Default. |
| Mellow Pulse | Lower, fuller tones with a softer attack. |

Both use the same motifs: a rising pair for start, a falling pair for stop,
and two low pulses for an error. These are
deterministic synthesized tones, without AI audio generation or third-party
recordings. REAPER and external services are not needed.

## Settings and playback

In **Dictation > Sound cues**, use the master switch to disable all cues, choose
a style, or preview Start, Stop, and Error separately. Settings save
immediately. Muting remembers the style and stops pending playback. Style changes
and previews are disabled during dictation; the mute switch remains available.

- Start plays asynchronously after microphone capture starts. Capture does not
  wait for the cue to finish. It plays through a standalone `AVAudioPlayer`,
  separate from microphone capture. Capture is not trimmed or muted during the
  cue. Without echo cancellation, a speaker-played cue can reach the microphone.
  Use headphones or turn cues off if this affects transcription.
  If system volume lowering is enabled, it happens
  after the cue finishes so its volume stays steady. With cues off, lowering
  starts immediately after capture begins. Stop/cancel cancels pending start
  feedback and waits for any in-flight volume change before restoring volume.
- Stop plays after capture ends and system volume is restored, including cancel.
- Error plays only when transcription fails, text refinement fails or cannot run
  because its model is unavailable/unsupported, or automatic insertion falls
  back to manual copy. Refinement errors still play when the raw transcript is
  used afterward. Intermediate insertion attempts do not play error cues when
  another fallback completes. Refinement waits for its preparation task; a
  preparation failure plays the error cue before using the raw transcript.
  Disabled refinement, empty transcripts, and recording/setup/cancellation problems do not play an
  error cue. Successful insertion is silent.

Cues play sequentially to prevent overlap. Stop/error playback does not
hold up transcription or insertion. Starting dictation interrupts previews and
old cues. Playback failures appear in the Sound cues section and do not block
dictation. Audio data is local; unused players are cached for the selected style
and each playback reserves its own player so delayed callbacks cannot stop a
newer cue. Players are prepared only when needed. No network calls, runtime synthesis, or idle audio
processing are added.

## Responsive startup

The app prepares an `AVAudioRecorder` on a serial background queue only after a
recording request and microphone permission approval. Launch and permission
approval alone cache sound files without preparing microphone I/O. The shortcut
shows a cancellable Starting pill immediately. The start cue plays only after
hardware capture starts. Recorder preparation, start/stop, and AAC finalization
stay off the UI thread.

Stop/cancel releases the recorder, metering timer, delegate, and input-device
observer. Preparation failures also release audio I/O, including failures before
a recording file exists. Each recording uses a fresh recorder with the current
input device. Logs report preparation time, capture readiness, and release time.
Use the opt-in hardware tests in `Tests/README.md` to compare capture APIs and
verify real AAC data and cleanup.

## Microphone capture and playback

The [audio capture README](../../Docs/Audio/README.md) explains the recorder
choice, measured latency, and the AUHAL option for a later comparison.

The recorder uses mono AAC at 44.1 kHz without native Voice Processing I/O.
Voice processing reduced other apps' playback volume even before capture started
and added substantial preparation latency. `AVAudioRecorder` writes AAC directly;
its meter feeds the waveform through a lock-protected status snapshot. Device
changes, encoding errors, and unexpected stops are reported rather than silently
transcribing a failed capture. File protection and private local storage are
preserved.

All cues and previews use standalone `AVAudioPlayer` instances. Capture never
connects microphone audio to playback. With System audio set to Unchanged,
DictaFlow does not lower output volume. The optional Lower setting still applies
only during recording and restores volume on stop, cancel, failure, or quit.

There is no native echo cancellation. Speaker playback, including the start cue,
can reach the microphone. Compare cue-only silence and speech with cues enabled
and disabled. Headphones or disabled cues reduce this risk. Bluetooth devices
using their own microphone can still switch to a hands-free profile under macOS;
use a separate microphone when preserving Bluetooth playback quality matters.

## Audio format and source

Six production assets live in `Resources/SoundCues/`, totaling about 215 KB.
They are mono, 48 kHz, 24-bit PCM WAV and last 0.185 to 0.363 seconds. The numbered
folders here contain matching individual cues and a `preview.wav` combining
Start, Stop, Error with 0.85-second gaps. Previews and scripts are not
bundled in the app.

Smooth sine-squared attack/release envelopes prevent abrupt edges. Levels match
the strongest 50 ms RMS at -25.5 dBFS with a -17 dBFS peak ceiling. This matches
short-pulse energy without boosting a cue because of its silent gap; it is not a
claim of equal perceived loudness on every output device. Deterministic 24-bit
triangular dither keeps quiet fades free of correlated quantization. Playback
volume follows the Mac's output volume.

Regenerate and validate with Python 3, without additional dependencies:

```sh
python3 Prototypes/AudioCues/generate.py
PYTHONDONTWRITEBYTECODE=1 python3 Prototypes/AudioCues/verify.py
```

The validation checks format, duration, headroom, DC offset, endpoints, sample
steps, matched levels, and exact correspondence between preview and bundled cues.
It can also check the built app's resources by passing that directory as an
argument.

After building the dev app, run the standalone playback checks. These substitute
silent players; they never play sound or access the microphone:

```sh
xcrun swiftc -swift-version 5 -default-isolation MainActor \
  Models/SoundCue.swift Models/DictationCapture.swift \
  Services/Audio/AudioRecorderService.swift \
  Prototypes/AudioCues/RecordingAudioBufferSink.swift Services/Audio/RecordingAudioWorker.swift \
  Services/Audio/SoundCueService.swift \
  Prototypes/AudioCues/verify-playback.swift -o .build/verify-sound-cue-playback
.build/verify-sound-cue-playback \
  '.build/DerivedData/Build/Products/Debug/DictaFlow Dev.app'
```

Verify the historical AVAudioEngine candidate writer with synthetic PCM.
Production AVAudioRecorder checks are covered by the opt-in hardware tests.
The synthetic check creates temporary audio files and checks AAC finalization
and the actual Whisper decoding service, without
opening a microphone, playing sounds, or creating an audio engine:

```sh
xcrun swiftc -swift-version 5 -default-isolation MainActor \
  Models/SoundCue.swift Models/DictationCapture.swift \
  Services/Audio/AudioRecorderService.swift \
  Prototypes/AudioCues/RecordingAudioBufferSink.swift Services/Audio/RecordingAudioWorker.swift \
  Services/Audio/SoundCueService.swift \
  Services/Whisper/AudioDecodingService.swift \
  Prototypes/AudioCues/verify-native-capture.swift -o .build/verify-native-capture
.build/verify-native-capture
```

## Manual checks

With continuous video or music playback, launch the installed Dev app and leave
it idle. Playback volume should remain unchanged. Repeat after permission
approval, a completed recording, cancellation during Starting and recording,
and an audio-device failure. Compare first and repeated startup timings in the
AudioCapture logs. With playback set to Unchanged, recording must not duck other
audio. Check both system-volume behaviors, and confirm the Starting pill remains
responsive and cancellable.

Run the mock-only coordinator checks for responsive startup, cancellation during
blocked preparation, cue overlap, mute, volume restoration, interruption/error
alerts, and termination. These use isolated settings and never capture/play audio
or change the clipboard or system volume:

```sh
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" \
  -configuration Debug -derivedDataPath .build/DerivedData \
  -only-testing:DictaFlowTests/RecordingStartupTests test
```

Install the dev app in `/Applications/` before checking real permissions, hotkeys,
and insertion. Listen on speakers and headphones, and Bluetooth if used. Check
both styles, every preview, mute and style persistence after restart, quick
repeated hotkeys, cancellation, volume lowering/restoration, insertion, and
error/manual-copy paths. Verify start/stop cues do not appear in a transcript.
Actual playback, output-route latency, cue leakage, and perceived quality need
this listening check; numerical validation does not replace it.

Compare cue-only silence and speech starting immediately with cues enabled/disabled,
at low/high speaker volume and
with external microphones. Pay particular attention to first and final words,
very short recordings, immediate stop/cancel, muting during the start cue, volume
restoration, and input/output device changes during capture. Check the recorder's
startup time and Bluetooth mode changes as well as transcript quality.
