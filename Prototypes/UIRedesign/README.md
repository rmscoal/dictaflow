# DictaFlow UI prototype

An interactive macOS UI proposal with a new visual direction called **Ember**: warm graphite, champagne highlights, rounded inset surfaces, and an ivory light appearance. This version follows the supplied SuperWhisper, OpenWhispr, menu bar, and curved desktop references through three new review rounds.

This folder contains the design artifact and its implementation record. The Ember interface is now implemented in native SwiftUI/AppKit; no frontend runtime or project dependency was added. The previous settings-style proposal and its review are preserved in `archive/`.

The final implementation target is recorded in [DESIGN_SIGNATURE.md](DESIGN_SIGNATURE.md), with the palette, geometry, single editing locations, required omissions, and eleven updated screenshots. [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) maps that target to the actual SwiftUI/AppKit files, implementation phases, and completion checks. See [NATIVE_REVIEW.md](NATIVE_REVIEW.md) for installed-app review, test results, and remaining verification limits.

## Open and explore

Open `index.html` in Safari or Chrome. It is self-contained, works offline, and does not need a build step or package installation.

The sidebar has three main destinations: **Dictation**, **History**, and **Settings**. **Updates** is a separate utility at the bottom. Settings groups **General** (shortcuts, audio, and storage), **Appearance**, and **Permissions**. Overview has been removed because its Start action, flow summary, and recording status already exist in Dictation.

Dictation keeps Transcription, Refinement, and Tone as three selectable stage cards. Use **Change…** to explore a model picker. **Menu bar** below the window opens the compact menu preview; its bottom section offers Settings and an update check. The sidebar can collapse, and its arrow keys move between the three main destinations.

The default preview is dark. Appearance offers Light and System as well. Resize the browser to inspect the fluid workspace. The green window control expands the prototype vertically; it does not maximize your actual browser or change macOS windows.

The controls below the app window belong to the prototype. Use **Scenario** to preview first launch, blocked permissions, missing models, failed downloads or transcription, no speech, and unavailable refinement. **Reset demo** restores the settings and sample history. **Design & review notes** explains the design inside the prototype.

Settings and sample data live only in memory. Reloading the page resets them.

## Feature coverage

| Existing capability | Prototype location |
| --- | --- |
| Start/stop dictation, local status, recording pill, cancel | Main toolbar, Dictation, menu bar preview |
| Transcribing, refining, and tone feedback; failed/empty recording recovery | Recording pill, History, and Scenario controls |
| Transcribe or translate to English | Dictation → Transcription |
| Automatic and all 100 supported input languages | Transcription → Input language; catalog taken from the vendored Whisper source |
| Six Whisper speech models and OpenAI logo | Transcription → Change… |
| Download, verification, progress, cancel, failure, retry | Each module’s model picker; a conditional toolbar accessory opens active or failed jobs |
| Optional Neural Engine encoder; bundle download, enable/disable/remove | Speech download confirmation and Neural Engine acceleration |
| Remove an individual inactive model | Trash action in the model’s row; selected and downloading models are protected |
| Open storage folder | Settings → General → Storage; the only storage utility, with no inventory or bulk cleanup |
| Protect the selected model from deletion | Each model picker |
| Local refinement on/off | Dictation → Refinement |
| Six current refinement models; Qwen, Google, Microsoft logos | Refinement → Change… |
| Five writing styles and additional instructions per style | Refinement → Writing style and Additional instructions |
| DIY system prompt, text preview, save, empty-prompt validation | Refinement → DIY style |
| Original, Casual, Balanced, Formal tone | Dictation → Tone |
| Tone without refinement, retained names/acronyms in examples | Tone preview and recording fallback |
| History search, sample replay, Original/Refined/Final results | History |
| Copy, insert again, retry with another installed model | History → visible actions above the recording text |
| Refine again | History → More actions |
| Previous results, retention Off/7/14 days, delete recording/all | History actions and History settings |
| Global shortcut capture, modifier validation, Escape cancel | Settings → General → Shortcuts & audio |
| Leave playback unchanged or lower volume | Settings → General → During recording; preference is simulated |
| Two sound styles and three cue previews | Transcription → Sound cues; uses the existing audio samples |
| Light, Dark, System appearance | Settings → Appearance; System follows browser OS appearance or the conversation’s preview theme |
| Solid-material accessibility preview | Settings → Appearance → Reduce transparency; proposal for respecting system settings |
| Microphone and Accessibility status and recovery | Settings → Permissions; Scenario controls |
| Copy fallback when insertion is unavailable | Settings → Permissions → Preview copy panel; Accessibility-off scenario |
| Development/release identity distinction; version and update controls | Bottom sidebar → Updates; version values are samples |
| Daily automatic checks, completed check, available update | Bottom sidebar → Updates; menu preview → Check for updates… |
| First-launch model preparation and permission sequence | Scenario → First launch |

**Pause supported apps** stays marked **Coming soon**, matching the current app. Selection, download, and per-row removal stay in Dictation; storage utilities live in Settings. Existing provider assets are embedded unchanged. Tone displays the DictaFlow mark because it uses local formatting rules, not a model provider.

The downloaded-models/storage disclosure has been removed from both pickers. Tone keeps “Works with or without refinement” as a plain note and omits the extra refinement summary card. Error and unavailable states use soft red surfaces, borders, icons, and labels in both appearances; the accepted Ember palette and workspace geometry are retained.

The latest simplification removes the duplicate Settings sound-cue link, all bulk unused-model cleanup UI, the Storage walkthrough, Appearance's recording indicator preview, the persistent Ready/shortcut footer, and Permissions' local-recording information card. Sound cues remain only in Transcription. The actual listening/processing panel is retained, and download activity moves to a toolbar icon that is hidden when idle. Empty space is left quiet instead of adding replacement cards.

## Design direction

The floating sidebar, curved stage cards, large reading surface, warm color system, and inset capture panel replace the earlier blue settings layout. Model and provider identity stay visible through the pipeline. Controls use familiar macOS behavior, while the composition gives DictaFlow its own character.

The app window and page have no fixed maximum width or centered reading-column wrapper. On wide windows, configuration and the output example share a flexible two-column layout. At compact widths, the example moves below the controls. Field groups also reflow to keep their controls usable. The model sheets retain a bounded width because they are transient dialogs.

Long recording text scrolls independently, keeping Copy and Retry visible. Background download feedback preserves editing drafts, caret position, and picker focus. Secondary audio and instruction controls remain behind disclosures.

The default window is sized for desktop use. At narrow conversation widths, the navigation becomes a selector so the prototype remains reviewable. This responsive preview does not propose an iOS version of DictaFlow.

### References

- User-supplied SuperWhisper appearance and home screenshots: desktop proportions, visible shortcut controls, and a quiet navigation layer.
- User-supplied OpenWhispr screenshots: provider visibility, model-selection clarity, and a workspace that uses available width. Its account, cloud, chat, and integration features are not part of this proposal.
- [Supplied menu bar design](https://cdn.dribbble.com/userupload/48469143/file/a411722f7731fedab7bcfb6d5fcbc197.png?resize=1504x1128&vertical=center): an inset primary surface inside a soft material shell.
- [Supplied curved desktop design](https://cdn.dribbble.com/userupload/48497065/file/d947af27d9394f449a558369e2f5c568.jpg?resize=3200x2400&vertical=center): floating navigation, nested corners, and clear separation between controls and content.
- [Apple Human Interface Guidelines: Materials](https://developer.apple.com/design/human-interface-guidelines/materials): glass for navigation and controls, with a separate content layer.

These are references for an original DictaFlow layout. Their artwork is not bundled or copied into the prototype.

## What is real and what is simulated

Navigation, selections, draft editing, validation, dialogs, sample-history filtering, and appearance changes work. Sound previews play existing DictaFlow cue samples. Copy writes the displayed text to the clipboard when the browser allows it; otherwise the panel offers manual selection.

Microphone capture, local inference, model/encoder downloads, checksum verification, history audio playback, permission changes, text insertion, output volume changes, and update checks are simulated. No microphone permission, cloud inference, update request, model download, or macOS setting change is performed. Recording produces clearly identified sample text. Refinement examples are static and do not respond to custom instructions. Tone examples illustrate a small part of the production formatter rather than porting all its rules.

The sample device is an Apple silicon Mac with 16 GB RAM. Model names, providers, approximate sizes, writing styles, and language choices were checked against the repository. The sample app version and target app, Notes, are not detected from the user’s system.

## Native implementation boundaries

See [NATIVE_COMPONENTS.md](NATIVE_COMPONENTS.md) for the proposed SwiftUI/AppKit component mapping and macOS compatibility boundaries.

- Keep `DictaFlowAppState` and protocol-backed system services. This prototype does not propose replacing the coordinator or adding a web runtime.
- Use native SwiftUI forms, controls, and SF Symbols. Use AppKit materials/window coordination for platform-specific surfaces. HTML blur approximates glass and does not reproduce native optical or vibrancy behavior.
- Keep macOS 14 compatibility with standard-material fallbacks. Adopt newer glass APIs only where available. Respect system Reduce Transparency and Reduce Motion.
- Preserve the insertion order: Accessibility direct insertion, clipboard paste, simulated typing, then copy panel. The prototype directly exposes the final fallback for review; it does not exercise the intermediate system methods.
- Request Microphone before recording. Request Accessibility when automatic insertion needs it. Keep permissions and app identity separate between dev and release targets.
- Keep real checksum checks, model-support/memory checks, download locking, atomic history updates, retention/deletion confirmations, and saved attempt metadata in the existing services.

## Verification and review

See [REVIEW.md](REVIEW.md) for the review loop, browser workflow checks, contrast measurements, width measurements, and remaining native validation. The final references are listed in the design signature; earlier screenshots remain as review history.

The final planning reference passed **99 workflow checks** and **132 layout measurements** across six widths. Screenshots prefixed `implementation-` show the current target. `feedback-` and `ember-` screenshots record earlier iterations.

The native Dev build and test suite passed: **108 tests, 21 skipped, zero failures**. Installed-app computer-use review is documented separately in [NATIVE_REVIEW.md](NATIVE_REVIEW.md). The browser checks above apply only to the HTML prototype; they do not establish real inference, permissions, downloads, or cross-app insertion behavior.

Icon attribution and the Lucide license are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). DictaFlow logos and sound samples come from the existing repository.
