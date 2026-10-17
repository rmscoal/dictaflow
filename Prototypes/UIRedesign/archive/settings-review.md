# Design review

## Goal and acceptance criteria

Create a realistic, interactive macOS prototype that keeps transcription, refinement, tone, provider branding, and all current core features. Model configuration belongs inside Dictation. The UI should make common choices easy, expose recovery actions, and remain readable in light and dark appearances.

This is a self-review of the prototype, not a claim of user-tested usability or verified native behavior.

## Round 1: hierarchy and navigation

**Verdict: revise.** The first layout had appropriate platform structure but too much visible secondary content.

| Finding | Severity | Refinement |
| --- | --- | --- |
| Default Transcription screen grew to about 1,145 px, beyond a practical desktop window | High | Use a bounded desktop window with a native-style scrolling content area; tighten grouping and spacing |
| Sound settings competed with speech model and task selection | Medium | Move sound controls into a labeled disclosure, retaining cue playback and style selection |
| “Change” and “View models” opened the same picker | Medium | Keep one clearly labeled model-picker entry |
| Language options initially contained only a subset | High | Restore all 100 supported languages plus Automatic from the vendored Whisper catalog |
| Model configuration could otherwise lose storage and cleanup features when Models navigation was removed | High | Keep download and cleanup within each module’s picker, behind an optional storage disclosure |

Evidence: `../reviews/round-1.png` captures the first screen. Final desktop frame and prototype controls fit within about 802 px at the tested desktop width.

## Round 2: behavior and feature correctness

**Verdict: revise.** Screen appearance was clearer, but state behavior needed more careful treatment.

| Finding | Severity | Refinement |
| --- | --- | --- |
| Unsaved additional instructions could disappear when changing tabs/styles | High | Keep drafts per writing style; keep prompt drafts; show an accurate unsaved indicator |
| Saving from prompt-preview mode assumed the textarea existed | High | Save the current draft from either editor mode; reject an empty prompt |
| Disabling an encoder was initially modeled as deleting its file | High | Track installed encoders and disabled encoders separately; allow enabling without another download |
| Downloading could be confused with selecting a new model | High | Keep the current model through download/verification; require explicit Use model |
| Refinement-unavailable output could still show refined text | High | Show the original transcript with tone; describe the unavailable runtime and recovery |
| Retry metadata and previous results could be inconsistent | High | Retain previous sample results and update the model/tone labels with the retry |
| Reset did not restore deleted sample history | Medium | Reset both preferences and the sample history fixture |
| Changing a shortcut did not initially change the prototype shortcut handler | Medium | Match the captured key code and exact modifier combination |

Evidence: `../reviews/round-2.png`. Workflow checks exercised download, selection, cancellation, failure, refinement drafts, prompt saving, history, and permissions. A later check found disclosure state could depend on the timing of a browser toggle event; rendering now also reads the actual open state before replacing modal content.

## Round 3: accessibility and final visual review

**Verdict: suitable for prototype review, with native validation still required.**

- Added arrow-key navigation and focus behavior to the three module tabs and history result tabs.
- Made the app behind a modal inert; added keyboard focus containment and Escape dismissal with focus restoration.
- Kept optional instructions behind a disclosure so the writing example receives more space. DIY prompts remain directly visible.
- Fixed dialog headers and actions in place while the model list and notes scroll.
- Kept all provider marks, a labeled selected state, and actionable text alongside color indicators.
- Increased small badges to 11 px and used explicit readable placeholder colors in dark mode.
- Added sidebar collapse and a first-launch preview with the existing permission sequence.
- Checked 1,120 px desktop, 728 px compact window, and 360/320 px narrow previews. The measured surfaces had no horizontal overflow. Narrow layouts are for reviewing the artifact, not a proposed new platform.
- Kept reduced-motion behavior and added a solid-material preview. Native implementation must follow system accessibility settings.

### Measured text contrast

| Pair | Light | Dark |
| --- | --- | --- |
| Primary text on content surface | 14.79:1 | 11.99:1 |
| Secondary text | 5.21:1 on the app background | 6.86:1 on the content surface |
| Link text on content surface | 5.09:1 | 6.83:1 |
| Selected navigation text on selection fill | 4.51:1 | 5.21:1 |

The destructive confirmation uses white text on a fixed red fill, measured at 5.33:1 in both appearances.

These are calculations for the declared colors, not a full WCAG audit. Native vibrancy, actual glass backgrounds, VoiceOver, increased contrast, and dynamic type need platform testing.

## Round 4: native structure and navigation

**Verdict: revise.** The structure was useful, but several controls still behaved like a web mockup rather than a macOS utility.

| Finding | Severity | Refinement |
| --- | --- | --- |
| Menu preview competed with the real recording action in the app toolbar | Medium | Move its trigger into the prototype controls; retain the compact menu surface |
| Sidebar selection and monochrome icons lacked a consistent accent treatment | Medium | Use a restrained accent selection, inherited icon color, and a clearer Overview symbol |
| Sidebar keyboard focus did not follow page selection | High | Add arrow/Home/End navigation with one current focus target |
| Search could leave an unrelated recording visible in the detail pane | High | Select the first matching recording, or show a matching empty state |
| Retry was hidden while Copy and Insert were readily visible | Medium | Put all three actions above the recording text |
| System appearance could disagree with a dark conversation preview | Medium | Follow the host theme when provided; otherwise follow the browser OS preference |

The native component proposal is documented in [NATIVE_COMPONENTS.md](../NATIVE_COMPONENTS.md). It keeps standard controls and the existing service architecture, with macOS 14 material fallbacks and availability-guarded macOS 26 glass.

## Round 5: asynchronous work and recovery

**Verdict: revise.** A pleasant default screen was insufficient when work continued in the background.

| Finding | Severity | Refinement |
| --- | --- | --- |
| Closing a picker made an active or failed download difficult to find | High | Add an actionable window status and a cross-provider activity link that returns to the right picker |
| Progress refresh could reset picker scroll/focus or disturb another editor | High | Preserve picker scroll/disclosures/focus; update only affected surfaces; preserve drafts and caret position |
| Downloading a speech model and its optional encoder required an extra step | Medium | Offer the encoder in the download confirmation; retain standalone encoder controls |
| Encoder installation, enabled state, and active job were not clear enough | High | Separate installed/disabled states; expose Cancel or Retry for the existing job |
| Processing had one generic label | Medium | Show Transcribing, Refining, and Applying tone with the active model; use indeterminate feedback for inference |
| Failed transcription and no-speech outcomes lacked a complete journey | High | Keep a failed/empty history record when retention is enabled; offer View recording and Try again; disable actions without text |
| History Off could still imply that failed audio was saved | High | State explicitly that History is off and the sample recording was not saved |

An initial expanded batch passed 43 of 43 workflow checks. Subsequent edge-case review led to the refinements in Round 6.

## Round 6: final interaction and visual review

**Verdict: ready for design review and native implementation planning.** The prototype meets the stated acceptance criteria at the tested widths and journeys. Native behavior and user-tested usability remain separate validation tasks.

- Long transcripts scroll inside the reading area, leaving Copy/Insert/Retry accessible above them.
- Previous attempts preserve status and model/refinement/tone metadata, including attempts that produced no text.
- Escape cancels a nested confirmation and restores its parent picker and trigger. Destructive confirmation starts on Cancel.
- Menu dismissal returns focus and preserves a live recording. A separate Escape can cancel that recording.
- Reduced transparency remains available during recording. Background download completion does not replace an unrelated live editor.
- Unavailable refinement is labeled unavailable rather than ready.
- Updated screenshots capture the refined surfaces. The final 60-check workflow batch passed after the appearance change.

### Final acceptance review

| Criterion | Prototype result |
| --- | --- |
| Core functionality and branding | All three modules retained; provider marks unchanged; model management stays in its module |
| Simple navigation | Seven consistent destinations, keyboard selection, three module tabs, collapsed sidebar, compact preview selector |
| Pleasant macOS appearance | Restrained navigation materials, accent selection, compact grouped controls, stable reading surfaces, light/dark support |
| Clear asynchronous feedback | Discoverable downloads, explicit processing stages, safe cancellation, recovery without silent model switching |
| Usable history | Search/detail agreement, visible actions, bounded reading area, preserved attempt metadata |
| Keyboard and confirmation behavior | Tab containment, focus restoration, safe confirmation default, predictable Escape behavior |
| Implementation feasibility | Standard SwiftUI/AppKit mapping; existing coordinator/services retained; no new production dependency |

## Workflow verification

JavaScript syntax was checked with `node --check`. Browser checks covered these user-visible outcomes:

- Seven pages; three core Dictation tabs; all language options.
- OpenAI, Qwen, Google, Microsoft, and DictaFlow marks retained in the correct modules.
- Selected model protected from removal; cancellation and failed downloads preserve the current selection; an explicitly selected downloaded model becomes active.
- Encoder disable/enable retains the downloaded file; canceled removal keeps it.
- Per-style draft preservation; saving instructions; saving a prompt from preview; blocking an empty prompt.
- Formal sample tone expands a contraction and retains the API acronym.
- History filtering, original text, retained retry results, no automatic insertion after retry, deletion, and reset.
- History Off prevents a newly simulated recording from being added.
- Blocked microphone shows permission recovery before recording. Unavailable insertion retains text in the copy panel.
- Runtime failure explains reinstall/recovery and preserves original text with tone.
- Update check completes with a clear status.
- Keyboard tab navigation, custom shortcut capture/start, recording cancellation, modal Escape, background inertness, and focus restoration.
- First launch offers speech-model preparation and delays the permissions to their intended use.
- Light/dark text color checks and layout overflow checks.

The original workflow batch passed 26 of 27 checks. The failed encoder/disclosure check led to a fix and passed in recheck. Additional checks uncovered a synthetic keyboard-event target edge case, which was fixed. One initial contrast calculation incorrectly handled three-digit hex colors; the corrected calculation produced the values above. Focus restoration was rechecked with focusable controls instead of assuming a programmatic click focuses a button.

Prototype sessions made no external resource requests after loading the self-contained HTML. Clipboard writes were not exercised in automated checks to avoid replacing the user’s clipboard. Sound assets were checked for embedding; audio output quality was not re-evaluated.

The collaborative browser connection became unavailable late in verification. Final keyboard, encoder, focus, contrast, layout, and expanded journey rechecks ran in T3’s HTML preview renderer. The final batch passed 60 of 60 checks using a deterministic timer fixture in a separate test copy. It exercised UI controls rather than invoking application-state hooks. The fixture is outside the deliverable; the delivered HTML uses normal browser timers. No real macOS action is claimed as tested.

The expanded checks additionally covered filtered history selection, nested confirmation cancellation, background download discovery across providers, optional model/encoder bundle downloads, editor identity/caret preservation, failed/empty recording recovery, previous failed attempts, processing stages, menu dismissal during recording, and appearance controls while recording.

Four additional appearance checks passed: System follows the dark preview host, explicit Light and Dark override it, and returning to System restores the host appearance. Layout measurements covered 12 surfaces at each of 1,120, 728, 360, and 320 px, with no horizontal overflow or controls outside the frame width. Those measurements check bounds; the screenshots provide the separate visual review.

The final artifact has 47 embedded assets and no external resource tags or timer-test fixture. The OpenAI, Qwen, Google, Microsoft, and DictaFlow assets match the prior prototype byte for byte. JavaScript syntax and text-file whitespace checks passed. Only `Prototypes/UIRedesign/` contains deliverable changes.

## Remaining risks and follow-up

1. Validate actual SwiftUI/AppKit materials and older macOS fallbacks. Browser blur is an approximation.
2. Try the proposed navigation with users before implementation. Self-review cannot establish discoverability or task success rates.
3. Test real microphone, global shortcuts, insertion fallbacks, clipboard restoration, model downloads/checksums, and history retention using an installed native build.
4. Validate VoiceOver, keyboard-only operation, larger text, reduced transparency, and increased contrast on macOS.
5. Keep the current protocol-backed services and data model. Static sample results and simplified in-memory attempts are not substitutes for production inference or history storage.
