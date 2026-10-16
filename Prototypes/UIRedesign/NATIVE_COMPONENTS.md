# Native implementation guide

Use the HTML prototype as a behavior and hierarchy reference. Implement the final interface with standard SwiftUI and AppKit components, retaining the existing application coordinator and services. A new UI framework or embedded browser is unnecessary.

The final visual contract is [DESIGN_SIGNATURE.md](DESIGN_SIGNATURE.md); the repository-specific work order is [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). These include the latest removals and replace earlier screenshots as the implementation baseline.

## Component mapping

| Prototype surface | Native component proposal | Behavior to preserve |
| --- | --- | --- |
| Window sidebar and content | Flexible SwiftUI shell, selection-bound native buttons or `List` | Three main destinations, visible selection, collapse control, keyboard navigation; match the floating inset sidebar; Updates is a separate bottom utility |
| Settings categories | A segmented `Picker` for General, Appearance, Permissions | Remember the selected category; expose keyboard selection; route permission recovery directly to Permissions |
| Toolbar | SwiftUI toolbar items and existing AppKit window coordinator | Leading sidebar control and title; trailing Start/Stop; disable changes that conflict with processing |
| Grouped settings | Native controls and `LabeledContent` inside explicitly styled sections | Match the approved radii, padding, and flexible tracks; do not let default `Form` geometry replace the composition |
| Transcription, Refinement, Tone stage cards | A selection-bound group of native buttons with provider images | Preserve the three modules, keyboard selection, and independent settings; expose the selected state to accessibility |
| Task, language, style, tone, sound choices | Native segmented/menu `Picker` | Keep complete catalogs and selected values; avoid custom popup infrastructure |
| Optional instructions, vocabulary, sound cues | `DisclosureGroup` | Secondary settings remain available without competing with primary choices; sound cues appear only in Transcription |
| Enabled settings | Native switch `Toggle` | Distinguish unavailable, disabled, and off states; appearance remains adjustable during recording |
| Model selection and management | A sheet containing grouped provider sections and model rows | Retain exact provider marks, selection protection, download/verify/cancel/retry, per-row removal, and encoder state; omit the duplicate downloaded-model list |
| Storage | Settings → General, with one native folder action | Open the current build's model directory; no inventory, unused-model count, bulk cleanup, or walkthrough |
| Tone guidance | Plain text with a quiet system symbol | Keep “Works with or without refinement” without repeating refinement settings |
| Download/delete confirmations | Native sheet or alert as appropriate | Optional encoder belongs in the download sheet; destructive actions default to Cancel; Escape returns to the parent picker |
| History | Searchable `List` and recording detail view | Search selects a matching record; Copy/Insert/Retry remain above scrollable text; retain failed attempts and their metadata |
| Additional instructions and DIY prompt | `TextEditor`, explicit draft state and Save action | Preserve drafts across navigation; support preview without losing the editable draft; validate empty prompts |
| Recording and processing feedback | Existing floating panel coordinator, `ProgressView`, text labels | Show Transcribing/Refining/Applying tone; percentages only for measurable download progress |
| Compact menu | `MenuBarExtra` and the existing menu-bar feature | Start/Stop, read-only pipeline links, shortcut guidance, History, Settings, Updates, Quit; no second preference editors; dismissal does not cancel recording |
| Permission and insertion recovery | Existing permission services and copy-panel coordinator | Request microphone before recording; request Accessibility when insertion needs it; retain actionable failure text |
| Appearance and symbols | Semantic SwiftUI fonts/colors, SF Symbols, existing provider image assets | Respect appearance, contrast, motion and transparency settings; provider logos retain their own identity |

Apple’s [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) supports sidebar/detail structure. [GroupedFormStyle](https://developer.apple.com/documentation/swiftui/groupedformstyle) and [LabeledContent](https://developer.apple.com/documentation/swiftui/labeledcontent) are available on macOS 13 and later, so they fit DictaFlow’s macOS 14 deployment target. These are component recommendations, not compiled implementation changes.

## Fluid window layout

Do not place Dictation inside a fixed-width centered wrapper. Let its root and stage row fill the content area, with normal window padding. Give configuration and preview flexible tracks, and move the preview below the controls when both tracks cannot fit comfortably. Keep the reading font stable as the window grows.

The prototype demonstrates this with CSS Grid and container queries. Translate that behavior to SwiftUI’s flexible stacks or adaptive layout. Avoid copying a fixed pixel width from a screenshot. Model-picker sheets can remain bounded; the main workspace should expand with the window.

The graphite/amber and ivory/brown palettes are product-specific. Use semantic color assets for them and standard state colors where appropriate. Keep the existing provider assets unchanged. Treat the floating sidebar and inset surfaces as visual treatments around native controls, preserving their keyboard and accessibility behavior.

Use semantic error colors for the soft red error surfaces, labels, and borders. Pair them with an icon, clear status, and recovery action so color is not the only signal. Keep update and storage utilities outside the primary Dictation workflow.

## Materials and platform compatibility

Keep glass concentrated in navigation, the toolbar, and transient controls. Keep reading and editing surfaces stable. This follows Apple’s [Materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials). Native materials handle vibrancy and optical behavior that CSS blur cannot reproduce.

On macOS 14 and 15, use native window chrome and standard SwiftUI/AppKit materials. Where custom AppKit surfaces need vibrancy, use `NSVisualEffectView` within the existing window/panel coordinators. Avoid layering a custom blur over controls that already provide their own material.

On macOS 26 and later, evaluate system-provided Liquid Glass first. Use [glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) only for a custom control that benefits from it, with an availability guard and an older-system fallback. Apple’s [Landmarks Liquid Glass sample](https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass) requires macOS 26 and Xcode 26. It is a platform reference, not a reason to raise DictaFlow’s deployment target.

Respect the system Reduce Transparency and Reduce Motion settings. Use an opaque or standard-material fallback when needed. Measure text against the actual rendered native surface; the HTML contrast calculations do not prove native vibrancy contrast.

## Integration boundaries

- Bind controls to the existing `DictaFlowAppState` and settings types. Keep draft UI state distinct from saved settings and active jobs.
- Keep microphone, hotkeys, model downloads, checksum verification, inference, history, permissions, insertion, and updates behind the existing services. UI redesign does not change their contracts.
- Preserve the insertion order: Accessibility direct insertion, clipboard paste, simulated typing, then copy panel. Restore previous clipboard content where supported by the existing service.
- Background download completion must not replace an already usable selected model. Preserve the existing first-usable-speech-model recovery exception; keep installation, enabled encoder state, and active selection separate.
- Persist history attempts atomically using the existing history service. The prototype’s in-memory objects illustrate presentation only.
- Keep production/dev app identity and permission behavior separate. Sample version numbers and target-app labels must be replaced with actual application state.
- The narrow HTML layout supports reviewing the prototype. Validate the actual minimum window width and resizing behavior in the macOS app rather than copying the browser breakpoints.

## Native validation still required

Test an installed build from `/Applications/` on the supported macOS versions. Check keyboard-only operation, VoiceOver reading order, longer localized text, system contrast/transparency/motion settings, permission transitions, hotkeys across apps, insertion fallbacks, real downloads/checksums, and history retention. Use actual inference timing to confirm that the processing labels and recovery paths remain useful.
