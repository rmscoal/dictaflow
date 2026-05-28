# DictaFlow

Turn speech into polished text, privately, from anywhere on your Mac.

DictaFlow is a native macOS menu bar app for private dictation. It records
your voice, runs local Whisper transcription or translation, optionally cleans
the text with a local LLM, and inserts the result back into the app you were
using.

It is for people who want dictation to feel like a keyboard shortcut: quick,
quiet, available in every writing surface, and not dependent on a cloud service.

## Why DictaFlow

- Private notes, messages, and drafts should stay on your Mac.
- Dictation should work in the app you are already using, not in a separate
  transcript box you have to copy from.
- Raw speech often needs cleanup before it reads well. DictaFlow can polish the
  transcript locally before insertion.
- Open source dictation should be inspectable, hackable, and honest about where
  data is stored.

## Highlights

- Local transcription through vendored `whisper.cpp`.
- One shortcut to start recording, stop recording, transcribe, and insert.
- App-aware insertion back into the previously focused app.
- Optional local cleanup through a `llama.cpp` compatible GGUF model.
- Checksum-verified model downloads.
- Transparent storage and privacy notes.

## Current Status

DictaFlow is in active development. The main development target is
`DictaFlow Dev` with bundle id `com.dictaflow.dev`.

The app is macOS-only and currently targets macOS 13.0 or newer.

## Features

- Menu bar app with a compact dictation control surface.
- Global toggle shortcut: `Command + Shift + Backslash`.
- Local Whisper task modes:
  - Transcribe in the spoken language.
  - Translate supported source languages into English.
- Whisper model choices:
  - Tiny
  - Base
  - Small, the default
  - Medium
- Optional local transcript refinement with supported GGUF models.
- Automatic model download with checksum verification.
- Insertion fallback order:
  - Accessibility direct insert
  - Clipboard paste
  - Simulated typing
  - Manual copy panel
- Settings for model choice, task mode, input language, refinement, and model
  storage cleanup.

## Privacy Model

DictaFlow is intended to be local-first:

- Microphone audio is recorded locally.
- Whisper transcription runs locally through `whisper.cpp`.
- Optional transcript refinement runs locally through a `llama.cpp` compatible
  runtime.
- There is no cloud transcription path, analytics pipeline, or remote inference
  service in the app code.

Current local data behavior:

| Data | Current behavior |
| --- | --- |
| Recordings | Written as temporary local `.m4a` files under `FileManager.default.temporaryDirectory/DictaFlowRecordings` with user-only permissions, then deleted after transcription finishes or fails. |
| Transcripts | Kept in process memory as the latest transcript for display, copy, and re-insertion. Local refinement writes a user-only temporary prompt file that is deleted after `llama-cli` exits or is killed. There is no durable transcript history file or database. |
| Models | Stored under `~/Library/Application Support/DictaFlow/Models`. |
| Clipboard | Clipboard insertion may temporarily place transcript text on the pasteboard with transient/concealed pasteboard markers. DictaFlow attempts to restore previous pasteboard contents when it can confirm the paste succeeded. |
| Logs | Whisper diagnostics log audio statistics and transcript length, not transcript contents. |

## Requirements

- macOS 13.0 or newer.
- Xcode with macOS SwiftUI/AppKit tooling.
- Network access for first-time model downloads.
- Microphone permission for recording.
- Accessibility permission for automatic insertion into other apps.
- Optional: `llama-cli` available in the app bundle. Debug builds can also use
  `/opt/homebrew/bin` or `/usr/local/bin` for transcript refinement during development.

## Build

Use the main Xcode scheme:

```sh
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" -configuration Debug -derivedDataPath .build/DerivedData build
```

For local-only builds on a Mac that does not have the project owner's Apple
Development signing identity, use ad-hoc signing:

```sh
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" -configuration Debug -derivedDataPath .build/DerivedData build DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-
```

The `Ensure Whisper XCFramework` Xcode build phase builds
`Vendor/whisper.cpp/build-apple/whisper.xcframework` via
`Vendor/whisper.cpp/build-xcframework.sh` when needed.

## Run Locally

For behavior involving permissions, hotkeys, text insertion, model storage, or
app launch, use an installed app from `/Applications` instead of relying only
on a DerivedData run.

The repo includes convenience Make targets:

```sh
make run        # build, install to /Applications, and launch DictaFlow Dev
make build      # build and install without launching
make verify     # build, install, verify signing, and launch
make logs       # build, install, launch, and stream process logs
make telemetry  # build, install, launch, and stream subsystem logs
make debug      # build, install, then start lldb
```

## First Run

1. Launch `DictaFlow Dev`.
2. Allow microphone access when prompted.
3. Let DictaFlow prepare or download the selected Whisper model.
4. Focus the app where you want dictated text inserted.
5. Press `Command + Shift + Backslash` or use the menu bar control to start recording.
6. Press the shortcut again to stop, transcribe, and insert.
7. Grant Accessibility permission if you want automatic insertion beyond manual
   copy/paste.

## Project Layout

```text
App/                 App entry point and DictaFlowAppState coordination
Core/Windowing/      AppKit window and fallback panel coordinators
Features/MenuBar/    Menu bar UI
Features/Settings/   Model, task, language, refinement, and storage settings
Models/              Codable and value types
Services/            Audio, permissions, hotkeys, models, Whisper, settings,
                     refinement, and text insertion boundaries
Vendor/whisper.cpp/  Vendored Whisper source and XCFramework build script
```

`DictaFlowAppState` is the main coordinator. System APIs are kept behind
protocol-backed services so behavior remains testable and replaceable.

## Model Storage

Whisper and refinement models are downloaded into:

```text
~/Library/Application Support/DictaFlow/Models
```

Downloads are written to a temporary `.download` file, verified against the
expected checksum, then moved into place. The settings UI can delete recognized
unused model files while keeping active models.

## Testing

There is currently no dedicated test target.

For now, verify manually with an installed app from `/Applications`, especially
for changes touching:

- microphone permissions
- Accessibility permissions
- global hotkeys
- text insertion
- clipboard restoration
- model downloads and storage
- app launch behavior

## Contributing

Contributions are welcome. Please keep DictaFlow local-first and avoid adding
cloud inference, analytics, telemetry, or remote transcription paths.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution licensing terms.

## License

DictaFlow is licensed under the GNU Affero General Public License, version 3 or
later. See [LICENSE](LICENSE).

Third-party notices are tracked in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
and [NOTICE](NOTICE).
