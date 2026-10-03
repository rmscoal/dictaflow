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
  wait for the cue to finish. It plays through the recording's `AVAudioEngine`
  with Apple's native voice processing enabled, so echo cancellation can reduce
  speaker playback in microphone input. Capture is not trimmed or muted during
  the cue. For best results on speakers, speak after the start sound.
  If system volume lowering is enabled, it happens
  after the cue finishes so its volume stays steady. With cues off, lowering
  starts immediately after capture begins. Stop/cancel cancels pending start
  feedback and waits for any in-flight volume change before restoring volume.
- Stop plays after capture ends and system volume is restored, including cancel.
- Error plays only when transcription fails, text refinement fails or cannot run
  because its model is unavailable/unsupported, or automatic insertion falls
  back to manual copy. Refinement errors still play when the raw transcript is
  used afterward. Intermediate insertion attempts do not play error cues when
  another fallback completes. Disabled refinement, a server still starting,
  empty transcripts, and recording/setup/cancellation problems do not play an
  error cue. Successful insertion is silent.

Cues play sequentially to prevent overlap. Stop/error playback does not
hold up transcription or insertion. Starting dictation interrupts previews and
old cues. Playback failures appear in the Sound cues section and do not block
dictation. Audio data is local; players are cached for the selected style and
prepared only when needed. No network calls, runtime synthesis, or idle audio
processing are added.

## Responsive startup

After microphone permission is granted, the app prepares the native engine on a
serial background queue. Preparation does not start audio hardware or create a
recording file. A shortcut shows a cancellable Starting pill immediately. The
start cue still plays only after hardware capture starts, so it means the
microphone is ready. Start/stop and AAC finalization never block the UI thread.

Stop/cancel pauses audio hardware, detaches the capture sink, drains the writer,
and retains the engine graph and tap. The next recording gets a fresh private
AAC file and sink without rebuilding voice processing. No idle samples are stored.
Device configuration changes invalidate the prepared graph; the next start
rebuilds it. An interrupted active capture still fails visibly. Quitting shuts
hardware down and removes a pending temporary capture.

Initial permission approval, recording immediately during app startup, or an
audio-device change can require cold preparation. The pill remains responsive
and cancellable during that work. Logs report background preparation time,
request acknowledgement, capture readiness, and whether idle hardware is stopped.
These are measured service timings, not a claim of identical audible latency on
every output route.

## Native echo cancellation

The recorder uses `AVAudioEngine` voice processing throughout each recording,
including when cues are disabled. The start cue uses a player node in that same
engine. The microphone feeds a capture tap only, never the output mixer, to avoid
live microphone feedback. Stop, error, and settings previews use the standalone
player after capture ends; previews never start microphone input.

Capture and output use the same explicit mono client format. This is required by
Voice Processing I/O and avoids encoding the aggregate device's microphone and
reference channel layout as AAC. Recording failures appear in a main-window alert
as well as status text; write failures also log their system error domain/code.

The meter and AAC recording use the same processed microphone buffers. A bounded
pool copies tap buffers before they can be reused; a serial writer performs AAC
encoding and file I/O away from the tap. Stop/cancel drains accepted buffers and
closes the file before transcription or deletion. File protection and local
temporary `.m4a` storage are preserved. Audio hardware is paused while idle; prepared resources are retained for the next recording.

Automatic gain control is disabled to avoid additional microphone level changes.
Apple's other-audio ducking is set to its minimum, with dynamic ducking disabled.
Minimum is not a guaranteed zero reduction of other audio; listen with both
DictaFlow system-volume behaviors. DictaFlow's optional master-volume adjustment
still happens after the cue and is restored on stop, cancel, interruption, or quit.

If voice processing cannot start, recording fails with an actionable message;
it does not silently fall back to unprocessed capture. A changed/stopped device,
write failure, or exhausted buffer pool interrupts capture, restores volume,
and reports the problem instead of transcribing an incomplete recording.

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
  Services/Audio/RecordingAudioBufferSink.swift Services/Audio/RecordingAudioEngine.swift \
  Services/Audio/SoundCueService.swift \
  Prototypes/AudioCues/verify-playback.swift -o .build/verify-sound-cue-playback
.build/verify-sound-cue-playback \
  '.build/DerivedData/Build/Products/Debug/DictaFlow Dev.app'
```

Verify the capture writer with synthetic PCM. This creates temporary audio files
and checks AAC finalization and the actual Whisper decoding service, without
opening a microphone, playing sounds, or creating an audio engine:

```sh
xcrun swiftc -swift-version 5 -default-isolation MainActor \
  Models/SoundCue.swift Models/DictationCapture.swift \
  Services/Audio/AudioRecorderService.swift \
  Services/Audio/RecordingAudioBufferSink.swift Services/Audio/RecordingAudioEngine.swift \
  Services/Audio/SoundCueService.swift \
  Services/Whisper/AudioDecodingService.swift \
  Prototypes/AudioCues/verify-native-capture.swift -o .build/verify-native-capture
.build/verify-native-capture
```

## Manual checks

Run the mock-only coordinator checks for responsive startup, cancellation during
blocked preparation, cue overlap, mute, volume restoration, interruption/error
alerts, and termination. These use isolated settings and never capture/play audio
or change the clipboard or system volume:

```sh
python3 Prototypes/AudioCues/verify-recording-flow.py
```

Install the dev app in `/Applications/` before checking real permissions, hotkeys,
and insertion. Listen on speakers and headphones, and Bluetooth if used. Check
both styles, every preview, mute and style persistence after restart, quick
repeated hotkeys, cancellation, volume lowering/restoration, insertion, and
error/manual-copy paths. Verify start/stop cues do not appear in a transcript.
Actual playback, output-route latency, cue leakage, and perceived quality need
this listening check; numerical validation does not replace it.

Native echo cancellation reduces speaker leakage but is not a promise of perfect
removal or unchanged speech on every device. Compare cue-only silence and speech
starting immediately with cues enabled/disabled, at low/high speaker volume and
with external microphones. Pay particular attention to first and final words,
very short recordings, immediate stop/cancel, muting during the start cue, volume
restoration, and input/output device changes during capture. Check the native
engine's startup time and Bluetooth mode changes as well as transcript quality.
