# Per-app writing styles: master plan

## Goal

Add per-app writing style presets to the refinement path: DictaFlow automatically refines with the style assigned to the app the user dictates into (Terminal, Claude, ChatGPT to Technical and Engineering; Slack, WhatsApp to Casual Text Messaging, as examples). Rules are user-customizable: browse apps, assign a style, change or remove assignments. All editing lives only in Dictation to Refinement, in a single combined Writing style card.

## Success Criteria

- Recording into an app with a rule refines with that app's style; apps without a rule use the default style; behavior is unchanged when the feature is off or no rules exist.
- Users can add apps (browse running/suggested apps, search, pick from disk), move an app to another style, and remove rules; the visible app list always reflects the currently selected style.
- Each app maps to exactly one style (one-to-one); moving an app that already has a style opens a readable confirmation listing each app's old to new style, and Cancel leaves everything untouched.
- Matching is keyed on bundle identifier, survives app renames, needs no new permissions, and stays local-only.
- The effective style is visible before recording (stage card, output example) and is recorded per transcription in history.
- Existing `RefinementConfiguration.mode` keeps working as the default style; old preferences migrate without data loss.

## Approach

Grounded in current code: `RefinementMode` has 5 presets (`Models/RefinementMode.swift`); the mode picker lives in `Features/Refinement/RefinementSettingsView.swift`; the insertion target is already captured at recording start as `pendingInsertionTargetApplication` in `beginRecordingFlow` (`App/DictaFlowAppState.swift`), and frontmost-app changes are already observed via `NSWorkspace.didActivateApplicationNotification`. Refinement runs after recording stops (`refinedTranscriptionIfNeeded`), reading the live config.

Key decisions:

1. **Snapshot at recording start, preview live.** The style used for a recording is resolved once from the insertion target captured in `beginRecordingFlow`. The output example follows frontmost-app changes live so the switch feels immediate, but switching apps mid-recording never changes in-flight audio. Alternative rejected: resolving at refinement time would let a mid-recording app switch silently change the style.
2. **Extend `RefinementConfiguration`, keep `mode` as the default.** Add `perAppStylesEnabled: Bool` and `appStyleRules: [bundleID: RefinementMode]` to the existing Codable struct (same UserDefaults key, existing migration pattern with `writingStyleVersion`). The dictionary shape itself enforces one-to-one; the UI adds the confirmation. No separate store. Display names are resolved live via `NSWorkspace`, never persisted, so renames do not stale rules.
3. **Pure resolver, tested in isolation.** New small type `RefinementStyleResolver.effectiveMode(for:bundleID, in:) -> (mode, source)` returning `.rule` or `.default`. Used by AppState at recording start, by the UI preview, and history (pass the effective config into refinement so `refinement.mode` already records it).
4. **Seed starter rules only for installed apps.** On first run after upgrade, pre-assign the well-known bundle IDs the user named (Terminal, ChatGPT, Claude to technical; Slack, WhatsApp to casual, plus iTerm2, Ghostty, Discord, Messages) but only when `NSWorkspace.urlForApplication` finds them installed. Everything remains removable. Alternative rejected: empty-by-default would make the requested examples not work out of the box; unconditional seeding would create dead rules.
5. **One combined Writing style card, style-filtered list, inline empty state.** No header count text and no banner. The card holds: Style picker (also the default), "Switch style by app" toggle, then "Apps using {style}" filtered to the selected style. Rows are slim (icon, name, remove; bundle ID on hover only). The footer is bandless and holds only the Add apps button (hidden when the list is empty). The empty state is a single integrated line: "No apps yet. (+) Add apps using this style." with only "Add apps" underlined and clickable, opening the picker. Moving an app that already has a style opens a small 425 pt confirmation listing each mover as icon plus name plus "Old to New", with Cancel / "Move N apps". Multi-style-per-app stays a non-goal.

## Steps

1. **Model plus resolver plus tests.** Extend `RefinementConfiguration` (Codable keys, `writingStyleVersion` bump, migration keeping `mode` as default); add `RefinementStyleResolver`; add `DictaFlowTests` cases for exact match, fallback, disabled flag, unknown/nil bundle ID, DIY, one-to-one overwrite semantics, and old-prefs migration.
2. **AppState wiring.** Add `recordingRefinementMode` snapshot next to `recordingTone`; resolve it in `beginRecordingFlow` from the captured target; refactor `savedRefinementPromptTemplate` to take a mode parameter; publish `frontmostExternalApplication` for the preview; verify history stores the effective mode.
3. **Combined Writing style card.** Merge the style picker row and per-app toggle into one `EmberPanel` in `RefinementSettingsView`: style-filtered app list with remove, bandless Add-only footer, inline empty state ("No apps yet. (+) Add apps using this style."), enable/disable collapse; update the stage-02 card detail ("Per-app on") and `OutputExampleView` to preview the frontmost app's style.
4. **App picker sheet plus move confirmation.** New sheet with search, Currently open (`NSRunningApplication`, regular policy, excluding self), Suggested, and NSOpenPanel browse; app icons via `NSWorkspace.icon(forFile:)`; multi-select adds to the current style; rows already on this style show "Uses this style" (disabled), rows on other styles show their style and trigger the move-confirmation alert on add (Cancel returns to the sheet with selections intact).
5. **Status surfaces plus polish.** Overlay/menu status text shows the effective style; stale rules (app not installed) show "Not installed" rather than auto-deleting; accessibility labels matching existing patterns.

## Validation Plan

- `xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" -configuration Debug -derivedDataPath .build/DerivedData build` and the new `DictaFlowTests` resolver/migration tests.
- Manual matrix with the Dev app installed in `/Applications`: assign Terminal to technical and Slack to casual; record into each and confirm history mode plus inserted text style; record into an unassigned app (default applies); switch apps mid-recording (style unchanged); switch the picker and confirm the list swaps; move an app between styles and confirm the modal lists old to new correctly, Cancel keeps the old style, Move applies; remove a rule (default applies); toggle the feature off (old behavior).
- Highest-risk check: verify real frontmost bundle IDs of ChatGPT and Claude desktop apps on a Mac with those apps installed, since third-party IDs vary by distribution.

## Risks / Open Questions

- Third-party bundle IDs (ChatGPT, Claude) must be confirmed on hardware during implementation; wrong IDs mean rules silently never match.
- Electron apps report the main app bundle ID for the frontmost app (helpers are non-regular policy and already filtered), so Slack matching is low risk.
- Non-goals: per-app tone (tone stays global), per-app model, per-window/SSH-session detection in Terminal, multiple styles per app, sync. None.

Assumptions: seed-when-installed starter rules (reversible); snapshot-at-start semantics; rules stored inside `RefinementConfiguration`.

## Prototype

The approved v4 interactive prototype is the visual contract and lives next to this plan: `./index.html` (repo path `Prototypes/PerAppWritingStyle/index.html`). Open it in a browser for the full-size version. It uses the Ember tokens from `Prototypes/UIRedesign/DESIGN_SIGNATURE.md`, so colors, radii, and spacing match the native app.

Exercise these flows before implementing:

1. Switch the Style picker between Normal Cleanup, Technical and Engineering, and Casual Text Messaging, and watch the app list swap to that style's apps.
2. With Technical and Engineering selected, open Add apps, select Slack (currently on Casual), and press Add to see the move-confirmation modal, then confirm or cancel.
3. Remove an app, toggle "Switch style by app" off and on, and try the Light/Dark switch below the window.
4. Use the "frontmost app" selector below the window to see the output example follow the effective style, and press Start Recording to see which style a recording would use.

Notes for the implementing agent:

- The controls below the window (frontmost-app selector, theme switch, reset) are prototype-only and do not ship.
- The prototype's `effectiveRule` logic mirrors the planned `RefinementStyleResolver`: exact bundle ID match wins, otherwise the default style applies, and the feature toggle bypasses all rules.
- App tiles in the prototype are letter placeholders; the native UI must use real icons via `NSWorkspace.icon(forFile:)`.
- The move-confirmation modal follows the design signature's small-confirmation size (425 pt reference width).
