# Ember design review

## Brief and decision

The earlier proposal stayed too close to the existing DictaFlow settings UI. This loop changes its visual identity and layout, using the supplied SuperWhisper, OpenWhispr, menu bar, and curved desktop references. The prior proposal and its review remain in `archive/` for comparison.

The new direction uses warm graphite, champagne accents, an ivory light appearance, floating navigation, curved stage cards, and an inset output surface. Dictation has a fluid configuration/preview workspace. The window and page have no fixed maximum width.

This is a strict self-review of a prototype. It does not establish user-tested usability or verified native behavior.

## Final implementation-planning refinement

**Verdict: ready to implement against the final signature.** This remains a prototype review, not verified native implementation.

The approved Ember palette and composition are retained. Sound cues have one editing home in Transcription. General no longer repeats a Feedback/Sound cues link. Storage keeps only Open storage folder, with no unused-model control, inventory, count, confirmation, or walkthrough. Appearance omits the decorative recording preview. Permissions omits the local-recording information card. The idle Ready/shortcut footer is removed and its space returns to the content. The real recording/processing panel remains.

Download activity now uses an icon accessory in the toolbar only while active or failed. Its accessible label identifies the state and model; it opens the relevant existing picker, and failed activity uses the soft red surface. No replacement idle status card was added.

- **99/99 interaction checks passed.** The earlier suite was adapted to remove obsolete cleanup checks and extended to verify each requested omission, single folder action, reclaimed footer height, retained live overlay, and toolbar download recovery.
- **132 layout measurements passed:** 22 surfaces at 320, 360, 728, 1120, 1440, and 1600 px. This includes active/failed toolbar download states. No horizontal or internal panel overflow was found.
- Eleven `implementation-` screenshots record the final Dictation, width/appearance variants, General, Appearance, Permissions, Tone, model picker, error treatment, and menu. They are attached in [DESIGN_SIGNATURE.md](DESIGN_SIGNATURE.md).
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) maps the design to inspected native files, old recovery routes, single editing locations, existing services, and native verification gates. It preserves the first-usable-model recovery exception found in the real coordinator.
- JavaScript syntax, embedded asset integrity, and planning links were checked. No Swift app source, dependencies, model files, history data, or production preferences changed. No Xcode build was run in this planning revision.

## Previous feedback refinement

The accepted Ember palette, workspace layout, curves, and provider assets are retained. This refinement reduces duplicate UI and navigation rather than introducing another visual direction.

| Feedback | Result |
| --- | --- |
| Too many main destinations | Dictation, History, Settings; Updates becomes a separate bottom utility |
| Combine secondary preferences | Settings has General, Appearance, and Permissions categories; General contains shortcuts, recording audio, and storage |
| Downloaded-model/storage disclosure repeats the picker list | Removed from both model pickers; per-row removal remains |
| Relocate the storage folder | Settings → General → Storage; cleanup is retained there without another model list |
| Keep the tone explanation, remove the repeated refinement setup | Plain “Works with or without refinement” guidance replaces the extra card |
| Errors blend into normal cards | Soft red backgrounds, borders, labels, and icons for missing/unavailable models, blocked microphone, failed downloads/encoders, and failed captures |
| Updates belong at the bottom | Bottom sidebar utility and a separate bottom menu action; the menu action starts the simulated check |

I recommend removing Overview from navigation. Its Start action, flow summary, and recording status duplicate Dictation; History already holds past recordings. Combining preferences into Settings reduces the main navigation without mixing configuration controls into the dictation workflow. Updates is infrequent, so it stays separate from the three main destinations.

### Feedback verification

- **95/95 workflow checks passed.** The previous 60 journeys were adapted to the new routes and encoder disclosure, then extended with 35 checks for the requested changes. These cover Settings keyboard navigation, preference persistence, folder feedback, cleanup confirmation/cancellation, selection protection, active-download protection, background storage counts, error surfaces in both appearances, permission recovery, update placement/actions, and shortcut capture/start.
- **120 layout measurements passed:** 20 surfaces at 320, 360, 728, 1,120, 1,440, and 1,600 px. They cover the three main destinations, Settings categories, Updates, the Dictation stages, model/provider pickers, the menu, and recovery states in dark and light appearances. No horizontal or internal panel overflow was found.
- JavaScript syntax and embedded assets were checked again. Native actions remain simulated; no Swift app code changed.
- A pixel comparison at 1,120 px found the default Dictation content, toolbar, and footer unchanged outside the sidebar. All 47 embedded assets also remain byte-identical to the accepted version.
- Screenshots from this round use `feedback-`; `ember-` screenshots and the Round 1–3 results below describe the preceding Ember version. The final implementation baseline uses `implementation-`.

## Round 1: replace the composition

**Verdict: revise.** The new identity was visibly different, but the first implementation needed better proportions.

| Finding | Severity | Action |
| --- | --- | --- |
| The earlier centered settings column did not use a maximized window | High | Remove width caps from the window and page; introduce flexible configuration and preview columns |
| Recoloring existing grouped forms would not meet the new brief | High | Rebuild the Dictation composition around three stage cards, a separate preview, and floating navigation |
| The new two-column layout squeezed the model name and controls at compact widths | High | Stack the preview below configuration when the content area is below 760 px |
| Heading, stage, and field spacing pushed common controls below the initial view | Medium | Tighten vertical spacing and model padding while retaining comfortable hit areas |
| Some new captions were only 9–10 px | Medium | Raise them to at least 11 px |

Evidence: `reviews/ember-round-1.png` records the first wide composition before these refinements.

## Round 2: carry the identity through the app

**Verdict: revise.** The Dictation screen was clearer; the surrounding surfaces needed the same treatment and careful state behavior.

- Rebuilt the menu around an inset capture panel, circular primary action, current models, and direct workspace/history access.
- Applied the graphite/amber identity to history, pickers, dialogs, recording feedback, and settings. Added an ivory/brown light appearance rather than returning to the previous blue palette.
- Kept provider images unchanged. Tone retains the DictaFlow mark because it uses formatting rules rather than a model provider.
- Changed the stage affordance from an external-link-style arrow to an internal chevron. The selected stage points down into its controls.
- Restored appropriate spacing between the refinement toggle and model section.
- Preserved model download/verify/cancel/retry, encoder state, editing drafts, failure recovery, history metadata, permission ordering, and focus behavior. The 60 existing browser workflow checks passed against the redesigned controls.

## Round 3: width, navigation, and final verification

**Verdict: ready for design review and native implementation planning.** The new direction meets the requested prototype criteria at the measured widths. Platform and user testing remain follow-up work.

The expanded layout review found an actual narrow Overview overflow. A grid track kept the minimum width of its recording panel and waveform. Flexible tracks, explicit zero minimum widths, constrained waveforms, and wrapping button contents corrected it. A mobile-only synthetic maximize check was removed because that control is hidden at narrow review widths; the visible desktop control is still tested.

The sidebar expand/collapse affordance now reflects automatic compact navigation and updates when the width breakpoint changes. Browser width checks found no remaining horizontal overflow or controls beyond the frame at the tested sizes.

### Width measurements

| Browser width | Window width | Dictation content | Configuration | Preview | Layout |
| --- | --- | --- | --- | --- | --- |
| 320 | 320 | 286 | 286 | 286 | Stacked |
| 360 | 360 | 326 | 326 | 326 | Stacked |
| 728 | 728 | 602 | 602 | 602 | Stacked |
| 1,120 | 1,120 | 854 | 461 | 369 | Two columns |
| 1,440 | 1,440 | 1,174 | 639 | 511 | Two columns |
| 1,600 | 1,600 | 1,334 | 728 | 582 | Two columns |

The content keeps growing between 1,120 and 1,600 px. Computed maximum widths for both the root and page are `none`. Only transient sheets and individual controls retain appropriate size limits. Requests for 1,920/2,560 px were capped by the renderer at 1,600 px, so those larger viewport sizes are not claimed as visually verified.

### Verification performed

- **60/60 workflow checks passed** after the final layout changes. They cover the three modules, all language choices, provider marks, model selection and downloads, encoder controls, draft saving, processing stages, failed/empty captures, history retries, copy fallback, nested confirmations, keyboard focus, menu dismissal, and first launch.
- **4/4 appearance checks passed** for explicit Light, explicit Dark, System following the dark host, and a further explicit Light override.
- **92 layout measurements passed** across six widths: seven pages, three module selections, speech and provider-specific refinement pickers, the menu, and compact sidebar states. Bounds checks include internal panel overflow, not only document width.
- JavaScript syntax passed `node --check`. The test copy uses a deterministic timer fixture; the delivered HTML uses normal timers and contains no test hooks.
- Visual review covered Transcription, Refinement, Tone, Overview, History, speech selection, the menu, compact layout, and the light appearance. Final screenshots use the `ember-` prefix.
- All 47 embedded assets decode successfully. Existing OpenAI, Qwen, Google, Microsoft, and DictaFlow images are byte-identical to the archived proposal. No external runtime resources or new production dependencies are required.
- Clipboard writes and audio output were not exercised by automated checks. The prototype retains working copy/manual-copy and existing cue preview controls.

The collaborative browser opened the local page but snapshot automation twice returned `Preview automation snapshot timed out after 15000ms.` Final visual and scripted UI checks therefore used T3’s HTML renderer. No native macOS behavior is claimed as tested.

### Declared text contrast

| Text/surface pair | Light | Dark |
| --- | --- | --- |
| Main text on surface | 12.81:1 | 13.18:1 |
| Secondary text on surface | 5.51:1 | 7.41:1 |
| Selected accent text on selected fill | 5.06:1 | 7.27:1 |
| Preview text on preview surface | 9.04:1 | 10.62:1 |
| Preview captions on preview surface | 4.71:1 | 6.72:1 |
| Primary action label on action fill | 6.78:1 | 8.80:1 |

These are calculations for declared colors, not a full accessibility audit. Native vibrancy, actual screen backgrounds, VoiceOver, increased contrast, and larger text still need platform testing.

## Feature and implementation boundaries

Transcription, refinement, tone, all current model/provider choices, vocabulary, audio cues, history, shortcuts, appearance, permissions, and updates remain represented. Selection, downloads, and per-row model removal stay in Dictation; folder access is in Settings and bulk unused-model cleanup is removed. No account, cloud inference, analytics, or unrelated competitor features were introduced. The feature/location table remains in `README.md`.

Recording, inference, downloads/checksum checks, permission changes, history audio playback, text insertion, volume changes, and updates remain simulated. Sample results and in-memory settings are design tools, not a replacement for the existing services. No Swift app source changed and no Xcode build was required.

See `NATIVE_COMPONENTS.md` for the SwiftUI/AppKit mapping, flexible layout requirements, and macOS 14 material fallback. Validate the native implementation from `/Applications/`, including real permissions, shortcuts across apps, insertion/clipboard restoration, model downloads, inference, retention, VoiceOver, system accessibility settings, and actual window sizing. Test navigation with users before considering usability established.
