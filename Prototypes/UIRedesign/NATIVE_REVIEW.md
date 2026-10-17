# Native Ember review

Reviewed 15 October 2026 against [DESIGN_SIGNATURE.md](DESIGN_SIGNATURE.md) and the eleven `reviews/implementation-*.png` references. The final tested build is installed at `/Applications/DictaFlow Dev.app`.

## Result

The main window uses the approved warm graphite/champagne and ivory palettes, floating sidebar, fluid workspace, three stage cards, rounded configuration surfaces, and reading panel. Navigation is Dictation, History, Settings, with Updates at the bottom. Settings contains General, Appearance, and Permissions.

All requested simplifications are implemented. Sound cues have one editing location in Transcription. Storage exposes only Open storage folder. No bulk unused-model cleanup, downloaded-model inventory, walkthrough card, decorative recording preview, persistent Ready/shortcut footer, duplicate Tone refinement card, or Permissions local-recording card is shown. Individual inactive-model removal remains in its picker. The real recording overlay remains in place.

Existing provider assets, preferences, model identities, storage schema, local inference services, and insertion fallback services are retained. The prototype harness is not bundled in the native app.

## Review rounds and corrections

1. **Theme and shell:** built and inspected the installed Dev app. Replaced the old centered maximum width, consolidated destinations, and applied the two palettes and actual macOS window controls.
2. **Dictation and Settings:** inspected all three stages, both model catalogs, and Settings categories. Adjusted heading spacing, sidebar typography, module positioning, and output line spacing against the reference. Replaced an unreliable download menu primary action with a visible Download button and explicit confirmation.
3. **Wide and compact layout:** reviewed a wide 1800-point window, the standard 1120-point window, and the 660-point minimum. Wide content expands; compact configuration stacks. Long real model names exposed uneven stage heights, corrected with an equal-height row and verified again in the final installed build.
4. **Recovery and editing:** missing speech models now open their picker with a visible explanation; microphone denial routes directly to Permissions. Added a confirmed DIY reset action and retained explicit Save and unsaved drafts. Native computer use verified Write/Markdown Preview, reset confirmation, and Cancel without changing the saved prompt. The original writing style was restored.
5. **History and utilities:** inspected history list/detail, search and no-match states, shortcut capture cancellation, Appearance, Permissions, and Updates. A real update check returned up to date. Search review led to regression tests for delayed queries, pagination reset, no-match selection, and preserving previous results.

## Visual comparison

At standard width, visual comparison placed the main content origin, stage row, selected-model panel, and reading panel within approximately 1 point of the corresponding reference positions. This is a manual comparison, not an automated pixel-difference measurement. Final compact review confirmed aligned card bottoms with Whisper Large V3 Turbo and Gemma 4 E2B IT QAT, which are longer than the prototype sample models.

Native SF font metrics, control sizing, traffic lights, sheets, and system material rendering are intentionally OS-owned. Actual saved settings also change wrapping and preview height. Navigation and transient surfaces use lightly tinted system material with an opaque Reduce Transparency fallback; editing surfaces remain stable. Reduce Motion suppresses sidebar animation.

Native screenshots were inspected through computer use during the review. They were not exported as comparison artifacts. The PNG files in `reviews/` remain prototype references.

## Build and tests

Commands used:

```sh
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" \
  -configuration Debug -derivedDataPath .build/DerivedData build
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" \
  -configuration Debug -derivedDataPath .build/DerivedData test
```

- Dev build: passed.
- Targeted recording startup/history checks: 46 tests, zero failures.
- Full suite, repeated after the final source changes: 108 tests, 21 skipped, zero failures.
- Skipped tests require optional pinned model weights; weights were not downloaded for this review.
- `git diff --check`: passed.
- Existing Swift concurrency warnings remain; they were not part of this UI change.

Ignored local evidence: `.build/ember-targeted-tests.log`, `.build/ember-final-tests.log`, and `.build/DerivedData/Logs/Test/Test-DictaFlow Dev-2026.10.15_11-51-21-+0700.xcresult`.

This worktree initially lacked build artifacts. The matching repository's ignored Whisper XCFramework and llama source cache were reused to build. No vendored source was changed. The final bundle passed strict code-signature verification before installation. Previous installed Dev bundles are retained under `.build/EmberIterationBackups/`.

## Verification limits

The redesigned menu bar compiles and its routes were reviewed in source, but the native popover could not be opened reliably through the available computer-use surface. The automation exposes the main window and application menus, not its status item. Control-F8 and inspection of the View menu did not expose it. Its visual match and operation with the main window closed remain a manual check.

Real recording/inference, model and encoder download cancellation/checksum failures, permission denial/revocation, hotkey activation across other apps, insertion fallback and clipboard restoration, audio-volume restoration, live recording overlay behavior, retention deletion, and complete VoiceOver navigation were not manually exercised in this pass. Their existing services remain in place; automated tests cover applicable coordinator and storage behavior, but do not replace these system-boundary checks.

No user model/history file was deleted, no prompt reset was executed, and no macOS security permission was changed. Appearance and writing-style changes used for review were restored. No commit or push was made.
