# AGENTS.md

## Project

DictaFlow is a native macOS-only Swift app for private local dictation. It records microphone audio, transcribes or translates it with local `whisper.cpp`, then inserts the resulting text into the previously focused app.

## Architecture Map

- `App/`: app entry point, `NSApplicationDelegate`, and `DictaFlowAppState` orchestration.
- `Core/Windowing/`: AppKit window and fallback panel coordinators.
- `Features/MenuBar/`: menu bar extra UI.
- `Features/Settings/`: model, task mode, language, and storage settings UI.
- `Services/`: system boundaries for audio recording, permissions, hotkeys, model downloads, Whisper, settings, and text insertion.
- `Models/`: Codable/value types and UI state enums.
- `Vendor/whisper.cpp/`: third-party vendored Whisper source and XCFramework build script. Avoid edits unless explicitly requested.

## Build & Verification

- Main scheme/target: `DictaFlow Dev`.
- Bundle id: `com.dictaflow.dev`; display name: `DictaFlow Dev`.
- macOS deployment target: 13.0.
- Build with:

```sh
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" -configuration Debug -derivedDataPath .build/DerivedData build
```

- There is currently no test target. For behavior that touches permissions, hotkeys, text insertion, model storage, or app launch, also verify manually with an installed app from `/Applications/`; do not rely only on a DerivedData run.
- The Xcode build phase `Ensure Whisper XCFramework` builds `Vendor/whisper.cpp/build-apple/whisper.xcframework` via `Vendor/whisper.cpp/build-xcframework.sh` when needed.

## Implementation Rules

- Keep the app local-first. Do not add cloud inference, analytics, telemetry, or remote transcription paths.
- Preserve the permission flow: request Microphone before recording; request Accessibility only when automatic insertion needs it; refresh permission state on launch.
- Keep dev/release identity separated. Do not mix bundle identifiers, display names, app support paths, or permission assumptions between targets.
- Respect the insertion fallback order: Accessibility direct insert, clipboard paste, simulated typing, copy panel.
- Keep `DictaFlowAppState` as the main coordinator unless a change clearly belongs in a service or small model type.
- Use protocol-backed services for system APIs so behavior remains testable and replaceable.
- UI is SwiftUI, but macOS-specific windowing, activation, paste panels, hotkeys, and Accessibility belong behind AppKit/CoreServices coordinators or services.
- Avoid silent failures. Surface actionable status text or window UI when recording, model preparation, transcription, hotkey registration, permissions, or insertion fails.

## Data & Privacy

- Recordings are temporary local `.m4a` files.
- Whisper models are stored under `~/Library/Application Support/DictaFlow/Models`.
- Model downloads must verify checksums before use.
- Clipboard-based insertion should restore previous pasteboard content when possible.

## Style

- Follow existing Swift style: small focused types, explicit state enums, `@MainActor` for UI-facing coordination, actors for background Whisper/download/decoding work.
- Prefer native macOS controls and system symbols.
- Keep copy concise and user-facing; this app should feel reliable, private, and quietly native.
