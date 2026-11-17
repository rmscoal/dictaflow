# AGENTS.md

## Project

DictaFlow is a native macOS-only Swift app for private local dictation. It records microphone audio, transcribes or translates it with local `whisper.cpp`, then inserts the resulting text into the previously focused app. It also provides Agent Voice: local spoken renditions of coding-agent replies, submitted by connected hosts over a local MCP bridge and synthesized on device.

## Architecture Map

- `App/`: app entry point, `NSApplicationDelegate`, and `DictaFlowAppState` orchestration.
- `Core/Windowing/`: AppKit window, fallback panel, recording overlay, and Agent Voice speech-panel coordinators.
- `Core/UI/`, `Core/Appearance/`, `Core/Branding/`: shared Ember components and button styles, theme, and app marks. Reuse these instead of restyling controls per feature.
- `Features/MenuBar/`: menu bar extra UI.
- `Features/Settings/`, `Features/Refinement/`, `Features/History/`, `Features/Dictation/`: model, task mode, language, storage, refinement, and history UI.
- `Features/AgentVoice/`: Agent Voice General and History tabs, host setup cards, host brands, and manual setup snippets.
- `Services/`: system boundaries for audio recording, permissions, hotkeys, model downloads, Whisper, settings, and text insertion.
- `Services/AgentVoice/`: Agent Voice coordinator, host installer, and host availability probing for Codex, Claude Code, and Muse Code.
- `Packages/AgentVoice/`: self-contained Swift package. `AgentVoice` holds the voice contract, SQLite store, local bridge, and Liquid speech runtime; `AgentVoiceMCP` holds the tool adapter and PreToolUse `HookGuard`; `DictaFlowMCP` is the bundled `dictaflow-mcp` helper executable hosts launch.
- `Models/`: Codable/value types and UI state enums.
- `Docs/AgentVoice.md`: the Agent Voice lifecycle, host-boundary, and verification contract. Read it before changing Agent Voice behaviour; keep it accurate when behaviour changes.
- `Vendor/whisper.cpp/`: third-party vendored Whisper source and XCFramework build script. Avoid edits unless explicitly requested.

## Build & Verification

- Main scheme/target: `DictaFlow Dev`.
- Bundle id: `com.dictaflow.dev`; display name: `DictaFlow Dev`.
- macOS deployment target: 14.0.
- Build with:

```sh
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" -configuration Debug -derivedDataPath .build/DerivedData build
```

- `DictaFlowTests` covers refinement lifecycle and optional real-model inference; see `Tests/README.md`. Agent Voice package tests run with `swift test --package-path Packages/AgentVoice`; hosted Agent Voice and host-installer tests live in `DictaFlowTests`. For behavior that touches permissions, hotkeys, text insertion, model storage, app launch, Agent Voice host setup or hooks, or speech playback, also verify manually with an installed app from `/Applications/`; do not rely only on a DerivedData run.
- The Xcode build phase `Ensure Whisper XCFramework` builds `Vendor/whisper.cpp/build-apple/whisper.xcframework` via `Vendor/whisper.cpp/build-xcframework.sh` when needed.

## Implementation Rules

- Keep the app local-first. Do not add cloud inference, analytics, telemetry, or remote transcription paths.
- Preserve the permission flow: request Microphone before recording; request Accessibility only when automatic insertion needs it; refresh permission state on launch.
- Keep dev/release identity separated. Do not mix bundle identifiers, display names, app support paths, or permission assumptions between targets.
- Respect the insertion fallback order: Accessibility direct insert, clipboard paste, simulated typing, copy panel.
- Keep `DictaFlowAppState` as the main coordinator unless a change clearly belongs in a service or small model type.
- Use protocol-backed services for system APIs so behavior remains testable and replaceable.
- UI is SwiftUI, but macOS-specific windowing, activation, paste panels, hotkeys, and Accessibility belong behind AppKit/CoreServices coordinators or services.
- Every button must be clickable across its whole component frame, including padding and the gap between icon and text. Plain SwiftUI labels only hit-test their drawn glyphs, so give button styles and multi-part labels a `contentShape` that covers the full frame (as the Ember button styles do); never ship a button whose spacing or padding is dead. When adding or reviewing UI, audit `buttonStyle(.plain)` controls with icon-and-text labels first, and prefer the shared Ember styles over ad-hoc plain buttons.
- Avoid silent failures. Surface actionable status text or window UI when recording, model preparation, transcription, hotkey registration, permissions, or insertion fails.

## Agent Voice Rules

- Keep Agent Voice local-first: hosts talk to the app only through the bundled `dictaflow-mcp` helper and the private local socket. Do not add remote MCP servers, cloud speech, or transcript scraping; prompt text comes only from the hook's explicit payload fields.
- Only the main (user-facing) agent may open voice interactions, submit renditions, admit playback, or interrupt speech. Enforce this from host-supplied identity only (Codex `_meta` thread/session IDs, Claude Code hook `agent_id`, Muse session/thread variables), never from model-supplied tool arguments such as a self-declared `agent_id`, thread, or role.
- Respect the supported host floors the installer enforces (Codex 0.156.0, Claude Code 2.1.118). Missing or unverifiable caller identity must fail closed for voice while the written answer continues; do not weaken this to fail open.
- Do not add `${agent_id}` to Codex hook templates: Codex fails a hook when an optional field is absent. Codex children are identified by thread versus session ID, not by `agent_id`.
- Host-facing status must not claim ready when a required host capability is unverified, for example when the Codex version probe fails or the PreToolUse guard is missing or stale.

## Data & Privacy

- Recordings are temporary local `.m4a` files.
- Whisper models are stored under `~/Library/Application Support/DictaFlow/Models`.
- Model downloads must verify checksums before use.
- Clipboard-based insertion should restore previous pasteboard content when possible.
- Agent Voice history lives in the app-identity Application Support store (`AgentVoice/voice.sqlite`); dev and release stores, sockets, and installation IDs stay separate. Retained history follows the user's retention setting (up to 30 days, capped at 500 interactions); generated audio is not retained.

## Style

- Follow existing Swift style: small focused types, explicit state enums, `@MainActor` for UI-facing coordination, actors for background Whisper/download/decoding work.
- Prefer native macOS controls and system symbols.
- Keep copy concise and user-facing; this app should feel reliable, private, and quietly native.
