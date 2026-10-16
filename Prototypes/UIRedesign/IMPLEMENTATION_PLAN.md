# Native Ember implementation plan

Status: implemented and reviewed, 15 October 2026. The installed Dev build uses native SwiftUI/AppKit. See [NATIVE_REVIEW.md](NATIVE_REVIEW.md) for iteration results and remaining manual verification limits.

Deliver the approved Ember interface in native SwiftUI/AppKit, using the [design signature and attached screenshots](DESIGN_SIGNATURE.md) and [final interactive reference](index.html). Keep DictaFlow's local processing, model/provider support, history, permissions, and recording behavior. The latest requested removals are part of the baseline, not optional cleanup after implementation.

## Scope and decisions

Keep three primary destinations: Dictation, History, Settings. Place Updates at the sidebar bottom. General, Appearance, and Permissions are categories within Settings. Dictation retains Transcription, Refinement, and Tone as the three stage cards.

Each preference has one editing location, as listed in the signature. In particular, sound cues exist only under Transcription. Storage contains only **Open storage folder**. Remove bulk unused-model cleanup UI, its counts and confirmations, the storage walkthrough, decorative recording preview, persistent Ready/shortcut footer, and Permissions' local-recording information card. Do not move these removed cards or bulk cleanup to another screen.

Individual inactive-model removal stays in the relevant model picker. Keep the live recording/processing overlay. These two distinctions preserve core behavior while applying the requested simplifications. No existing model or history file is deleted by adopting the redesign.

This is a native UI replacement. Do not add a WebView, frontend runtime, design-system package, cloud inference, analytics, telemetry, or a new storage schema. Preserve macOS 14 support and dev/release identities.

## Baseline findings that guided implementation

| Current code | Required change |
| --- | --- |
| `App/ContentView.swift` contains the sidebar, most settings pages, model dialogs, and many private components | Separate the new shell and feature views into small focused files while wiring them to the same coordinator |
| `DetailPage` constrains content to `AppLayout.contentMaxWidth = 640` | Remove the main-page width cap and the centered wrapper; implement the fluid layout from the signature |
| `MainWindowPage` includes Overview, Models, and separate configuration destinations | Replace with Dictation, History, Settings, Updates; use explicit settings category, dictation stage, and picker presentation state |
| `showMainWindow()` resets navigation to Overview | Open Dictation initially and preserve the current destination when reopening an existing window; explicit links select their target |
| Recording, model failure, and refinement recovery paths route to `.models`, `.refinement`, or `.overview` | Update every call site and its user-facing text, not just sidebar buttons |
| `SettingsWindowCoordinator` and `openSettingsWindow()` route to `.shortcutAndAudio` | Route both to the single Settings interface; no second settings editor |
| `Features/Settings/SettingsView.swift` has an older parallel settings form, with no current view call site found | Repurpose it as the new Settings container; remove its duplicate task/language/model controls |
| `MenuBarView` has another speech model menu and refinement toggle | Replace them with the approved three read-only stage links; keep capture, Settings, History, update check, and Quit |
| `HistoryViewModel.refresh()` always passes an empty search to the store | Bind the new search UI to `HistoryStore.entries(search:limit:offset:)`; retain bounded pagination and generation checks |
| `finishWhisperDownload` can select the first usable model when no other prepared speech model exists | Preserve this recovery behavior. Background downloads must not replace an already usable selected model. Explain selection when first-model recovery occurs |
| Native model storage includes old files not necessarily present in the current catalog | Keep them on disk; folder access remains available. Do not reintroduce an inventory or bulk cleanup screen |

## Implemented file structure

The implementation follows these feature boundaries using the existing filesystem-synchronized Xcode groups. `ModelPickerSheet.swift` hosts both catalogs; `RefinementModelsView.swift` owns the refinement catalog. History uses `HistoryDetailView.swift` and `HistoryPlaybackView.swift`, with the recording list kept in `HistoryView.swift`. `Models/MainWindowPage.swift` and `SettingsCategory.swift` define navigation; `App/DictaFlowAppState+Presentation.swift` handles download presentation. No package or project-file change was needed.

| Area | Updated existing files | Added views/types |
| --- | --- | --- |
| Appearance and reusable surfaces | `Core/Appearance/AppTheme.swift` | `Core/Appearance/AppLayout.swift`; focused surface, button, and error styles under `Core/UI/` |
| Window shell | `App/ContentView.swift`, `Core/Windowing/MainWindowCoordinator.swift` | `Features/Navigation/AppSidebar.swift`, `MainWindowToolbar.swift` |
| Navigation and presentation | `App/DictaFlowAppState.swift`, `Core/Windowing/SettingsWindowCoordinator.swift` | `Models/MainWindowPage.swift`, `SettingsCategory.swift`; typed model picker presentation |
| Dictation | `Features/Dictation/WhisperModelsView.swift`, `ToneSettingsView.swift`, `Features/Refinement/RefinementSettingsView.swift` | `DictationWorkspaceView.swift`, `DictationStageCard.swift`, `TranscriptionSettingsView.swift`, `OutputExampleView.swift` |
| Model dialogs | Existing speech and refinement model row logic | `ModelPickerSheet.swift`, `SelectedModelCard.swift`, `Features/Refinement/RefinementModelsView.swift` |
| Settings | `Features/Settings/SettingsView.swift`, `AppearanceSettingsView.swift`, existing shortcut capture/content | `GeneralSettingsView.swift`, `PermissionsSettingsView.swift` |
| History | `Features/History/HistoryView.swift`, `HistoryViewModel.swift` | `HistoryDetailView.swift`, `HistoryPlaybackView.swift` |
| Utilities and secondary windows | `Features/MenuBar/MenuBarView.swift`, `Features/Onboarding/OnboardingView.swift`, `Core/Windowing/RecordingOverlayCoordinator.swift`, `CopyFallbackPanelCoordinator.swift` | `Features/Updates/UpdatesView.swift` |

Retain existing `AppTheme` names where practical and add clear semantic roles for paper, action foreground, selected surfaces, and error fill/outline/content. Move the current private layout constants to one shared location. This is internal UI structure; settings keys, model identifiers, service protocols, database fields, and app-support paths do not change.

Do not create a generic schema-driven settings renderer or a new state framework. Share a component only when multiple views need the same appearance and behavior. Keep provider assets in `Resources/Assets.xcassets`; do not regenerate them.

## Implementation order and verification criteria

The phases below record the implementation contract. They are not a claim that every real-device regression scenario was exercised. Actual results and untested boundaries are listed in the native review.

### 1. Theme and shell

Implement both palettes, typography, radii, and spacing from the signature. Build the floating sidebar, selection states, toolbar, and conditional download accessory. Use actual macOS window controls and the existing main window coordinator. Retain the current 660×520 minimum and saved window frame; choose approximately 1120×820 for a new window when the visible screen can accommodate it.

Remove the 640 pt `DetailPage` maximum and avoid recreating it in another wrapper. The root content, stage row, and workspace must expand. Use flexible SwiftUI layout with a width-based stacked fallback. Do not copy the prototype's fixed content height, faux traffic lights, or browser-only mobile navigation.

Gate: Dark and Light shell screenshots at compact and wide widths match the signature; titlebar controls and dragging work; no footer or empty footer spacer exists. Build after this phase.

### 2. Routes and consolidated Settings

Use `MainWindowPage` for Dictation, History, Settings, and Updates. Add `SettingsCategory` for General, Appearance, Permissions; retain `DictationSettingsTab` for the three pipeline stages. Picker presentation should identify speech/refinement and the relevant model for recovery.

Update `showMainWindow`, `showMainWindowPage`, `openSettingsWindow`, the settings window coordinator, help links, menu links, and all recovery call sites. Update status messages that currently say **Open Models**. Missing speech routes to Transcription and its picker; missing refinement routes to Refinement; blocked access routes directly to Settings → Permissions. Keep navigation as presentation state, without changing persisted preference keys.

Reuse `GlobalShortcutCaptureView` and the existing begin/candidate/cancel methods. Cancel capture when leaving General, closing the window, or opening another presentation. Preserve modifier validation, Escape cancellation, registration feedback, and recording locks. General also binds system audio behavior and `openModelsFolder()`. Keep the existing unsupported pause-apps row explicitly marked Coming soon; do not implement playback pausing as part of this task.

Appearance binds `updateAppAppearance`. Follow system transparency/motion accessibility preferences without adding a new saved app preference. Permissions uses the existing live permission states and system-settings actions. Prototype-only preview controls do not become fake production settings.

Gate: every preference has one editing home; all removed routes, duplicate editors, and requested cards are absent. Opening Settings from every entry point reaches this same container. Relaunch preserves existing saved preferences.

### 3. Dictation workspace and model pickers

Build the stage cards, selected-model identity, configuration column, and reading surface. Preserve all task modes, input languages, vocabulary, six speech models, refinement models/providers, five writing modes, DIY prompt editing, and four tones. Use the repository catalogs, current support/memory checks, and existing provider images rather than copying sample values out of the HTML.

Transcription contains the only sound-cue controls. Refinement owns its only enable switch, writing style, per-style additions, and DIY editor. Preserve unsaved drafts across stage/category changes and picker presentations, explicit Save, reset, and empty-prompt validation. Unsaved text must not reach inference.

Tone retains **Works with or without refinement**, with no extra refinement card. Use `TextToneFormatter` for its example. Other output previews are explicitly labeled sample examples; changing settings must not run inference or record audio merely to populate a preview.

Move catalog and individual download/remove operations into the corresponding model sheets. Keep selection, downloaded state, enabled encoder, and active jobs separate. Preserve download confirmation sizes, optional model+encoder ordering, cancel/retry, checksum verification, unsupported states, selected/downloading protection, at least one usable speech model, and model-plus-encoder removal confirmation. Download completion preserves a valid active selection, with the existing first-usable-model exception described above.

The picker owns download details, Cancel, and Retry. Outside it, a conditional toolbar icon links to the relevant active/failed job; it does not create another management panel. Keep backgrounds stable while progress changes, so text drafts, scroll positions, and focus are not reset.

Gate: stage selection and every catalog choice work; keyboard and VoiceOver selection states are correct; active downloads remain reachable after dismissing the picker; errors use the red signature; storage inventory and bulk cleanup are absent.

### 4. History and recovery presentation

Translate the reference's recording list and selected detail pane to the existing `HistoryViewModel` and store. Add query state and bounded store-backed searching, not filtering only the already loaded entries. Cancel or invalidate stale search results with the existing generation pattern. Preserve selected attempts where possible; stop playback when changing recordings or leaving History; clear unrelated detail when a query has no matches.

Keep Copy, Insert again, and Retry visible above scrollable text. Preserve Original/Refined/Final views, saved model/provider metadata, previous attempts and their parent relationships, retry confirmation, Refine again, failure/no-speech states, retention, and deletion confirmations. Retry does not silently change the global model or automatically insert a reviewed history result.

Route recording and refinement failures to an actionable inline error or existing failure alert. The removed footer must not be the only presentation of `statusMessage`. Use the existing recording/transcription/insertion enums and per-model download error dictionaries. If a failure currently exposes only text, carry an explicit presentation severity or recovery route with it rather than matching localized message strings. Preserve raw-transcript fallback with the chosen tone when refinement fails.

Gate: search covers persisted history, pagination and query races are correct, earlier attempts remain attached to their original transcription, and errors remain visible without an idle footer.

### 5. Menu bar, Updates, onboarding, and live panels

Apply the signature to the compact capture surface. Pipeline rows show the active provider/model or tone and open that stage. Remove the second speech selector and refinement toggle. Keep Start/Stop, live busy states, shortcut guidance next to capture, History, Settings, bottom update action, and Quit. Opening settings dismisses the popover; dismissing it never cancels a capture.

Extract the existing Updates page into its bottom utility. Bind real version/build identity, cached available release, `checkForUpdates`, `openAvailableUpdate`, and the saved automatic-check preference. Retain the current trusted GitHub release handling and daily check behavior. Do not ship the prototype's sample version or simulated update controls.

Restyle onboarding and the actual recording/copy panels where shared theme values change. Update onboarding copy to point to Dictation for model selection. Keep the setup sequence and practice flow. Preserve the recording panel's nonactivating behavior, audio metering, Cancel/Stop, processing phases, positioning, and completion lifecycle. Do not introduce the removed recording preview as a settings feature.

The Copy fallback preview in HTML is a review mechanism. Production continues to present the real copy panel when insertion falls back. It must never expose a sample result as if it came from a real recording.

Gate: the app still works from the menu bar with the main window closed; recording does not steal target focus; update and permission actions use actual app state; no demo harness is bundled.

### 6. Native visual review and regression verification

First compare the native shell, one complete Transcription view, and General Settings against the final references. Correct spacing, colors, typography, and width behavior before finishing every screen. Then review all stages, model dialogs, history, errors, and menu bar in both appearances. Use the visual tolerances in the signature and record OS-owned chrome/material differences separately.

Build and run the existing test suite. Add focused tests for changed navigation/recovery routes and store-backed history search, including stale-query rejection, pagination reset, no-match selection, and preservation of earlier results. Do not add tests that merely duplicate padding constants or view markup.

```sh
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" \
  -configuration Debug -derivedDataPath .build/DerivedData build

xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" \
  -configuration Debug -derivedDataPath .build/DerivedData test
```

Prioritize `RecordingStartupTests`, `RecordingAudioStatusTests`, `SoundCueServiceTests`, `TextToneFormatterTests`, `RefinementWritingStyleTests`, `RefinementStorageTests`, and `HistoryStoreTests` for affected bindings. Run the remaining normal suite before completion. Real-model integration tests require their documented fixtures; report skipped fixtures separately. Do not download weights just to make an optional check pass.

Verify the installed Dev app from `/Applications/`, following [Tests/README.md](../../Tests/README.md). Check permission denial/grant/revocation, shortcut capture and activation across apps, target focus, insertion fallback order and clipboard restoration, real model/encoder progress and cancellation, refinement fallback, history retention, audio volume restoration, and app/menu launch/close behavior. Do not rely only on a DerivedData run for these boundaries.

Gate: builds and applicable tests pass, installed-app checks are recorded, and compact/wide Dark/Light screenshots match the final design without duplicated controls or removed content.

## Behavior that must remain unchanged

- `DictaFlowAppState` coordinates work; existing protocol-backed services own system boundaries.
- Microphone access is requested before recording; Accessibility is requested when automatic insertion needs it; permission states refresh on launch.
- Insertion tries Accessibility direct insertion, clipboard paste, simulated typing, then the copy panel. Restore prior clipboard content where the current service supports it.
- Models remain local, checksum-verified, and protected while selected or in use. Capture and inference locks still apply to conflicting edits.
- History attempts, audio, retention dates, and deletion semantics remain in the existing store; the redesign is not a database migration.
- Model directories, preferences, bundle IDs, release identity, and permission assumptions stay separate between Dev and release builds.
- No changes to Whisper, llama runtime behavior, prompts, tone rules, capture timing, or vendored sources are needed for visual fidelity.

## Evidence and remaining work

The native implementation replaces the old capped layout and duplicate settings editors. The final HTML reference remains the frozen design target: **99 interaction checks**, **132 layout measurements**, and eleven reference screenshots from the earlier prototype review.

The native Dev target built successfully. The full test suite completed with **108 tests, 21 skipped, zero failures**. Added regression coverage checks navigation and recovery routes, search pagination, stale-query rejection, and selected history results. Computer use reviewed the installed `/Applications/DictaFlow Dev.app` across compact, standard, and wide layouts, both appearances, all Settings categories, model dialogs, history search, updates, and prompt preview/reset cancellation.

[NATIVE_REVIEW.md](NATIVE_REVIEW.md) records the corrections made during those rounds. Exact cross-renderer pixel identity is not claimed: native SF text, controls, window chrome, and system materials differ from HTML. Live inference, downloads, cross-app insertion, permission changes, and the menu bar popover still need the bounded manual checks listed there. No model/history deletion or security permission change was performed for this review.
