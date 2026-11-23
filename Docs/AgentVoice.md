# Agent Voice

Agent Voice provides automatic, interruptible local speech for connected agent sessions. The originating agent writes a conversational rendition through MCP before its clean written answer. Liquid synthesizes that rendition locally. Dictation and optional text refinement remain local and take priority over agent speech. The external coding host retains its own inference arrangement.

## User experience

Under **Agent Voice > General**, enable Agent Voice and download the verified Liquid model. The Omdo menu bar also has an Agent Voice switch for quick access. Choose **Speak automatically** or **Play on request**. Automatic mode admits the current eligible rendition when the host reports Stop. Manual mode retains the response for explicit playback. General also contains host connections, manual configuration with a Copy action in each code block, and a collapsed MCP tool reference.

The **Speech model** section offers Liquid’s **Female** and **Male** voices, **American** and **British** English accents, and a **Playback speed** slider from 0.75× to 1.5×. The default is Female, American English, and 1×. Settings save immediately and apply to automatic replies and History replay. Omdo detects the language automatically and applies the chosen accent to English. Speed changes also apply during playback. A voice or accent change regenerates speech that is still being synthesized. Replies already playing finish with the voice and accent they started with.

**Test speech** generates and plays a four-sentence English sample locally with the current voice, accent, and speed. The button is available when Agent Voice is enabled, the model is ready, and dictation and agent speech are idle. While the sample plays, changing its voice or accent generates a new sample. The same button becomes **Stop test** during generation and playback. Starting dictation also stops the test immediately. Samples are never added to History.

Liquid downloads use the shared progress bar and toolbar Downloads list, with combined byte progress across both model files, a separate verification state, cancellation, and completion or failure notices. Opening the download returns to Agent Voice > General. Cancelling removes the partial transfer and any uninstalled temporary files. Previously checksum-verified and installed files remain available for retry. At launch, Omdo verifies the local files before showing the model’s status. The model becomes ready only after both files pass verification.

During a DictaFlow upgrade, Omdo commits local history and prompts before reusing the Liquid model. Omdo tries to clone each verified Liquid file on the same APFS volume. The clone shares the original data blocks. If cloning is unavailable, Omdo checks available space before copying the file. If the model needs attention, choose **Continue** to open Omdo or **Speech Model Settings** to go to the model card. After freeing space, choose **Restore from DictaFlow** to verify and reuse local model files. If Liquid is selected for dictation, **Use Whisper** appears when an installed Whisper model passes verification. Omdo switches providers only when you select that action.

If Omdo quits during the upgrade's Liquid import, the next launch clears the staged copy and resumes from any verified files already installed. If the retry needs more space or the old files are unusable, Omdo shows the model warning and lets you continue. Use the model card to retry after addressing the warning.

The floating control identifies the speaking session and provides Stop and Dictate. Hover over the pill to expand it. It collapses after the pointer leaves. Hover uses the pill’s destination bounds during a resize, so the animation can finish under a stationary pointer. The control does not take keyboard focus from the target app. The existing dictation shortcut also interrupts speech. Interruption is a deliberate button or shortcut action; Omdo does not listen continuously for speech over the agent.

Stopping the current response persists suppression for the interrupted interaction. Delayed Stop observations and corrections cannot automatically make it speak again. Explicit Play remains possible, and a new user turn is independently eligible.

A bubble's Stop cancels only its playback, preserving other queued responses. Stopping an older revision leaves the current response eligible. The toolbar and floating control's Stop clear active and queued speech.

Dictation holds audio priority through recording, transcription, refinement, and insertion. Responses arriving during that work wait in the queue. Stopping speech does not cancel the coding agent.

**History** lists sessions using prompt titles and recent message previews. Selecting a session opens its retained exchanges in chronological order, with prompts on the right and spoken responses on the left. Play, Copy, and timestamps stay inside the bubbles. Earlier spoken revisions remain available within their response bubble. Very long messages can be expanded in place.

Search matches session identities, prompts, and all spoken revisions. It keeps the complete matching session visible, highlights matching text, and provides previous/next exchange navigation. Session details contain the session ID and start time. Right-click a bubble for exchange details, diagnostics, or **Delete exchange**. The session header's trash button deletes every saved exchange in that session, including while searching. Both deletion scopes require confirmation and cancel affected active attempts. Play regenerates speech from the selected text; generated audio is not retained for exact replay. Ordinary dictation history remains separate.

## Lifecycle contract

1. `on_user_prompt_submit` creates an interaction and returns its internal input ID plus spoken-rendition instructions.
2. The model either explicitly skips routine speech with `skip_spoken_response`, or calls `prepare_spoken_response` with conversational text. This never starts speech by itself.
3. The model produces its written answer.
4. `on_stop` records the observation and makes the current rendition eligible unless the input was explicitly skipped or suppressed. Omdo applies the app's playback preference, suppression, freshness, and queue limits.
5. An automatic attempt is created at most once for that rendition. Duplicate Stop delivery does not replay it.
6. A corrected preparation creates a new immutable revision and supersedes active speech for older revisions. The new revision waits for a fresh Stop. Stop-before-preparation does not authorize a later rendition.

The [Codex hook contract](https://learn.chatgpt.com/docs/hooks) allows another Stop hook to request continuation. Therefore this feature provides interruptible, best-effort playback of a completion candidate, not proof that every host check has accepted a final answer. A revision may have been partly heard before a correction arrives. IDs and local timestamps do not prove source ordering. Native event/turn identities are used when available; a host without a turn identity can address its current session input, with correspondingly weaker late-event correlation.

### Intentional silence

The main agent may skip speech for acknowledgments and routine success confirmations with no substantive result, important caveat, or required next action. It still speaks substantive answers, unexpected outcomes, failures, blockers, and questions requiring a decision, even if only one sentence. Explicit requests for spoken confirmation take priority. The choice depends on the response and context, not prompt length or a word-count threshold. Speech must not be padded to meet a paragraph target.

For example, after “stage and commit,” “Committed as abc123” can remain written only. “The commit failed because a check found a possible secret” should be spoken. The written answer is always produced normally, without announcing a speech skip.

`skip_spoken_response` requires `session_id`, `input_id`, and a UUID `request_id`. Supply the current `replaces_draft_id` and `expected_revision` if a rendition exists. Omitting both asserts that no rendition exists, rather than allowing any revision. The helper applies the same main-agent identity checks as preparation. Missing or failed skip support must not cause repair loops or prevent the written response.

An accepted skip persists a separate `skipToken`, clears automatic eligibility, and cancels active or queued attempts only for that input, including manual playback already in progress. Retained renditions remain available as earlier responses with explicit Play and Copy actions. History shows “Speech skipped by agent” as the current decision, with no fabricated empty rendition. A later explicit manual replay does not clear the skip. Duplicate skip receipts and additional skips with distinct request IDs return the original token without cancelling that later replay.

To resume after a continuation, read the current token from the skip reply or `get_speech_status`, and pass it as `skip_token` to preparation along with any existing rendition replacement fields. Token and revision checks are atomic. A delayed tokenless preparation cannot undo a skip. Only successful preparation clears the marker; capacity rejection leaves the skip, retained text, and manual playback unchanged. Skipped inputs do not consume pending rendition capacity. Resumed preparation requires a Stop received afterward. Host callback identities cannot prove the source ordering of every independently delayed Stop; receipt deduplication is a separate guarantee.

Stop while skipped admits no audio, even when an earlier rendition exists. Stop without any rendition or explicit skip remains `awaitingCompletion`, so missed preparation is distinguishable from intentional silence. The skip decision survives playback, disconnect, and recovery, without reopening host mutation rights or clearing user suppression. Continuation remains subject to attachment, host closure, and the existing mutation window. With history Off, an inactive skipped input is settled and may be pruned; a receipt can still be retrievable, but a pruned input cannot resume. Pruning retains only its input, session, native turn identity, and timestamps until the original input’s retry window ends (24 hours by default). A matching Stop is acknowledged during that window without restoring prompt text, renditions, events, or playback rights. Explicit input and native turn IDs remain authoritative; unknown or expired identities are rejected. A session-only Stop addresses the latest known input, including a pruned skip.

The bridge authenticates the local OS user, not whether a tool invocation originated from a model or a host hook. Playback consent is the app setting; MCP callers cannot change it. Lifecycle messages still require a valid session attachment. No timer is presented as proof of finality.

Intentional-silence verification on 2026-11-18: all 123 package tests passed, including both arrival orders of skip/preparation, explicit continuation tokens, repeated skips during manual replay, receipt recovery, migration, retention Off, capacity rejection, user suppression, and child-agent rejection. The selected hosted Agent Voice, session history, and host setup suites passed 48 tests. A strengthened late-synthesis test also passed after waiting for resource retirement before asserting that no audio reached the player. The Dev build and strict deep signature verification passed.

The updated Dev app was installed under `/Applications`, with the previous app preserved under `.build/installed-app-backups/20261118-165313-agent-skip`. Its bundled helper listed six tools. A synthetic local rendition reached `playing`, an explicit skip stopped its attempt, and a following Stop preserved `skippedByAgent`. Native history showed the skip decision and earlier retained response; explicit Play reached the playing UI, and Stop returned it to an inactive state. Existing enable/playback settings and host configurations were preserved. These checks establish state transitions and installed UI behavior, not subjective audio quality or live host compliance with the revised instructions.

## Setup and host boundaries

The **Connections** section in General registers the bundled helper under the host alias `omdo`. Close the target host before choosing **Set up**, **Update**, or **Recover setup**. Codex and Muse Code can update an app-owned user-level registration. Claude Code and other hosts provide manual setup. A configured connection requires a new host session. In Codex, use `/hooks` to review and trust the changed hooks.

An upgrade replaces the old `dictaflow` registration only when its helper and app, installation, and host arguments match. Codex uses the effective user profile, including `CODEX_HOME`. The rename carries across the server’s existing settings and per-tool approvals. A fresh Codex registration includes `default_tools_approval_mode = "approve"`. Muse Code honors `XDG_CONFIG_HOME`, preserves the enabled flag, and changes the registration and guard in one settings write. An ownership conflict, unsupported config form, or custom hook that references either alias requires manual review, including Codex hooks defined in `config.toml`. Keep one managed Omdo registration per profile. Use different host profiles to connect Dev and release independently where the host supports profiles.

For manual migration, close sessions using the affected profile. Rename the old registration and its policy references in the same scope, update the executable path and arguments using the app’s snippet, replace only the related lifecycle hooks and command guard, and review workspace overrides before restarting. Preserve explicit approvals and disabled state. The helper binary and the server’s protocol identity are stable. Only the host alias and host-qualified tool names change.

Codex's hooks can supply native session and turn IDs. Claude Code has different event fields and requires its own configuration. Other MCP hosts need a lifecycle integration or manual playback; do not assume they implement Codex hooks. Lifecycle setup and supported versions must be checked using isolated host fixtures before claiming end-to-end support.

### Main-agent-only voice (Codex, Claude Code, Muse Code)

Only the user-facing coordinating agent may open voice interactions, submit renditions, admit playback, or interrupt speech. Child, nested, background, and custom agents must not speak, mutate parent drafts, or cancel parent playback. Independent top-level sessions are unaffected: each speaks for itself.

Enforcement uses host-supplied identity only, never model-supplied arguments:

- Codex requires stable 0.156.0 or later. Direct MCP requests carry host-written `_meta.threadId` and `_meta.sessionId`: only equal IDs may act, and the `session_id` argument must match them. Missing or malformed identity is rejected before attachment, receipt lookup, or store access. Child, nested, and background native threads retain the root session ID but have a different thread ID.
- Codex MCP lifecycle hooks instead carry the host-written `_meta.threadId` with `session_id` substituted from the hook payload. Only prompt, stop, and interrupt callbacks may use this hook form (without the direct-call `callId` or `sessionId` fields); their owning thread must match the hook session. Native children run `SubagentStop`, not `Stop`, and do not run `Interrupt`. The lifecycle hooks use the same helper connection as direct calls. Do not add `${agent_id}` to these templates: Codex fails a hook if an optional field is absent, including at root.
- Claude Code lifecycle hooks substitute `${agent_id}` into `on_user_prompt_submit` and `on_stop`. The helper rejects a non-empty value before any attachment or store contact. Missing, empty, or literally unsubstituted values are the main session. `agent_type` alone never proves a child (a root `--agent` session sets it) and is ignored.
- A PreToolUse command hook matching `mcp__omdo__.*` denies direct child model calls to every Omdo tool. The helper answers from the host's hook input (`agent_id` for Claude; `MUSE_SESSION_ID` versus `MUSE_THREAD_ID` for Muse) and exits 0 in all cases so the host always continues.
- Muse documents command hooks only, so it receives the guard but no lifecycle hooks. Its lifecycle stays model-driven through direct MCP calls, which the same guard filters. A Muse hook without both session variables denies loudly with an update prompt instead of silently passing as root.

External orchestrators that launch children as independent CLI sessions (for example T3) supply no ancestry. Each child looks like a top-level session and can speak in its own session.

Update Claude Code to 2.1.118 or later before applying the manual registration and voice hooks. Omdo checks this version before reporting the connection as configured. The manual snippets remain available on older versions. Supported versions supply `agent_id` for child hook events. The PreToolUse guard uses shell form so it runs on every accepted release (the exec-form `args` array needs 2.1.139 or later). Verification used isolated fixtures and deterministic tests.

The Codex contract was traced in the official [0.169.0 runtime](https://github.com/openai/codex/blob/rust-v0.169.0/codex-rs/core/src/mcp_tool_call.rs), [hook executor](https://github.com/openai/codex/blob/rust-v0.169.0/codex-rs/core/src/hook_mcp_executor.rs), and [session identity initialization](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/core/src/session/session.rs). The MCP identity pair is present in 0.156.0 and absent in 0.155.0. Clients must preserve this common runtime metadata; no T3-specific integration or model-supplied role flag is used. Desktop and cloud client qualification remains separate. If `caller_identity_missing` appears, update the host and start a new session; do not substitute identity arguments to bypass it.

Example Codex hooks for an MCP server named `omdo`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{
      "type": "mcp_tool", "server": "omdo", "tool": "on_user_prompt_submit",
      "input": {"session_id": "${session_id}", "turn_id": "${turn_id}", "prompt": "${prompt}"},
      "timeout": 2, "statusMessage": "Omdo: Agent Voice"
    }]}],
    "Stop": [{"hooks": [{
      "type": "mcp_tool", "server": "omdo", "tool": "on_stop",
      "input": {"session_id": "${session_id}", "turn_id": "${turn_id}"},
      "timeout": 2, "statusMessage": "Omdo: Agent Voice"
    }]}],
    "Interrupt": [{"hooks": [{
      "type": "mcp_tool", "server": "omdo", "tool": "on_interrupt",
      "input": {"session_id": "${session_id}", "turn_id": "${turn_id}"},
      "timeout": 2, "statusMessage": "Omdo: Agent Voice"
    }]}]
  }
}
```

Prompt text is optional and bounded to 4,000 characters. It is supplied explicitly; no transcript scraping occurs. Full written assistant messages and arbitrary host tool actions are not collected. Parent session relationships are not inferred from timestamps. Inserting dictated text into an app does not establish that it was submitted to an agent or sent as a message.

## Persistence and identity

The app owns `AgentVoice/voice.sqlite` under its Application Support identity. Dev/release have separate stores, installation IDs, model directories, and socket paths. The Unix bridge uses private directory/socket permissions and checks peer UID.

- Interaction: installation ID, host, session, optional native turn ID, internal input ID, and suppression/lifecycle state.
- Rendition: stable ID, interaction, immutable text, revision, and creation time.
- Attempt: separate ID, rendition, automatic/manual/legacy kind, playback state, and failure when present.
- Event: observed action and local time, with rendition/attempt references where applicable.

`VoiceReply.draftID` remains an alias for the stable `renditionID`; `attemptID` names a playback attempt. Compatibility `drafts()` projections use rendition IDs, while `nextJob()` returns an attempt ID for transition checks. Code must not compare these as if they were interchangeable.

Version 1 envelopes add optional `nativeTurnID` and `promptText`. Native turn mappings are persisted, but a reconnect closes old host mutation rights. A persisted mapping never authorizes reopening an old input. Unknown explicit turn IDs must not fall back to a newer turn.

Identical request UUID/envelope retries retrieve durable receipts. Changed payloads conflict. Receipts and the host mutation window last 24 hours. History lasts up to 30 days, capped at 500 interactions, with active playback protected during pruning. Queue expiry does not erase history or prevent explicit replay of retained text.

Migration imports retained legacy text and known playback outcomes, records migration as such, and does not invent missing historical events or resurrect expired renditions. Earlier overwritten revisions cannot be recovered. Restart and disconnect interrupt unfinished work without automatic replay. New prompts retire prior host mutation rights in that session, including turns whose playback already completed.

## Audio and resource policy

Foreground leases cover permission/startup, capture, ASR, refinement, and insertion. The first lease silences and suppresses current pending speech; nested leases preserve queued responses received during foreground work. Late synthesis results must pass generation and attempt-state checks before playback.

Foreground inference waits for the owned Liquid process to exit. Termination escalates after a bounded grace period. The process belongs to Omdo; unrelated inference processes are not stopped. Before TTS, idle Whisper/refinement resources are released. Liquid stops after synthesis before playback.

Current limits: 8,000 submitted rendition characters; five pending jobs per session and 50 globally; a five-minute automatic eligibility window for each prepared revision; five-minute queued/synthesizing attempt lifetime; a 60-second whole-response synthesis budget including startup; 12 MiB aggregate generated audio; playback shorter than 120 seconds including joins. Liquid ASR input is limited to two minutes or 8 MiB. Protocol, runtime, and audio safety limits still fail explicitly. Long speech uses the announced preview described below. Streaming is not implemented.

### Spoken wording and synthesis chunks

The agent submits one complete plain-text rendition. Its instructions ask for a calm, conversational tone, related sentences in short paragraphs, natural punctuation, preserved caveats, and commands described for listening. The agent should explain code and identify files naturally, keep exact commands/paths/URLs in the written answer, and aim for at most 220 spoken words. Pause tags, SSML, stage directions, Markdown, and artificial ellipses are not part of the speech contract. Multiple preparations replace revisions; they do not append chunks.

MCP preparation remains permissive within the existing protocol limits. Content does not trigger a correction/retry request to the agent. Omdo keeps the submitted text in history and derives a speech version locally at synthesis time, including manual replay of older entries:

- Foundation's Markdown parser removes formatting wrappers, keeps inline-code content and meaningful link/image labels, and preserves paragraph and list-item boundaries.
- Task-list markers at the start of a list item become "Completed:" or "Pending:" so completion status remains audible. Literal markers inside inline code or ordinary prose are retained.
- Common HTML formatting tags are removed only from parser-identified HTML outside inline code. Break/block tags preserve word boundaries. Unknown tags, generic types, and comparisons stay intact.
- Bare HTTP/HTTPS links use their hostname and explicit port, omitting credentials, paths, and query strings. Recognized file URLs use the filename. Inline commands and filenames otherwise keep their names and punctuation.
- Fenced or indented code blocks become "Code is available in the written answer." Tables receive a similar reference. Standalone blocks of consistently bordered pipe rows also get the table reference, even without a Markdown separator row; inline code and ordinary pipelines/operators are preserved. Omdo does not invent a semantic summary or silently delete a block.
- Unbroken Latin-script identifiers over 320 characters receive a short reference to the written answer. Formatting-only input also gets a spoken fallback. Unspaced non-Latin prose remains available to the language-aware splitter.

Fallback notices currently use English app copy. The initial rollout and real-model qualification focus on English. Other model-supported languages remain available as best effort, without new language-specific tuning.

English chunks contain up to three sentences and stop at 50 words or 320 characters, whichever comes first. Paragraph boundaries are kept. An oversized sentence is split at clauses, then word boundaries. These are guardrails qualified on reproduced English responses, not universal model limits.

If the derived plan exceeds 240 words, 1,600 characters, or eight chunks, it becomes an announced spoken preview, regardless of language. The first chunk says "This is a spoken preview. The full response is available in the written answer." This app notice is explicitly synthesized in English. The remaining chunks retain their own languages and form a continuous prefix of the cleaned rendition, ending at a planned chunk boundary. The notice counts toward all three budgets. The original submitted text is retained in full. A foreign phrase cannot disable the work bound for an otherwise English response. These fixed, conservative defaults bound work without another agent call; configuration is deferred. They do not guarantee a precise duration or synthesis time, so the runtime/audio safeguards remain. The shared resource guard does not establish multilingual voice quality; English remains the initial qualification focus.

The same owned Liquid process synthesizes all chunks serially. Decoded mono 24 kHz samples are combined into one WAV before playback. A failed or cancelled chunk discards the pending response, and every subsequent request checks cancellation and runtime ownership. The coordinator still treats the entire rendition as one playback attempt, retains dictation priority, and retires the model before playing audio.

Chunk joins target at least 120 ms of quiet audio within a paragraph and 250 ms at a paragraph boundary, counting quiet tails and heads already generated by Liquid. Generated samples are never trimmed. These initial pacing values are adjustable implementation choices, not exact prosody controls or a claim of better intonation. Voice naturalness needs listening checks.

Language is recognized locally from the cleaned rendition and its paragraphs using Apple's Natural Language framework, rather than unconditionally requesting English. Confident unsupported languages and unresolved longer prose fail with an actionable message. Ambiguous short Latin-script fragments inherit the rendition's language; a strongly recognized supported phrase of two or three words ending in sentence punctuation can override that context. An undetermined short acknowledgement defaults to English. Clearly identified paragraphs can use different supported languages, but switching languages inside one paragraph is not separately handled.

The pinned model supports English, Arabic, Danish, German, Greek, Finnish, French, Hebrew, Italian, Japanese, Korean, Dutch, Polish, Portuguese, Spanish, Swedish, Turkish, and Chinese. Non-English synthesis uses one-sentence chunks with conservative limits of 25 words / 160 characters (60 characters for Chinese, Japanese, and Korean); long unspaced text splits at grapheme boundaries. Multilingual quality and these limits require separate qualification. Each synthesis uses the selected Liquid voice for every chunk. The player adjusts playback speed after synthesis and uses the audio device’s completion callback to finish the attempt.

## Verification

Run `swift test --package-path Packages/AgentVoice` for contract, storage, migration, identity, lifecycle, and transport tests. Hosted `AgentVoiceTests` cover automatic playback, duplicate Stop during playback, revisions waiting for fresh Stop, persistent user suppression, manual mode, deletion, foreground priority, and late synthesis rejection. See `Tests/README.md` for app test commands.

`LiquidSpeechTests` and `LiquidSpeechTextTests` additionally cover cleanup of Markdown/links/code, literal punctuation and file identity, fallback references, bounded announced previews, abbreviations and decimals, paragraph boundaries, oversized clauses, grapheme-safe splitting, language selection and rejection, sample-preserving WAV assembly, boundary silence, aggregate limits, whole-response deadlines, and cancellation/failure between chunks. Store tests check that a non-compliant long rendition is accepted once and retained verbatim through automatic and manual playback admission. An opt-in real-model check uses existing pinned fixtures, writes synthetic audio under `.build/liquid-speech-check`, checks model retirement and cancellation, and plays nothing:

```sh
DICTAFLOW_RUN_LIQUID_SPEECH_CHECKS=1 swift test --package-path Packages/AgentVoice \
  --filter LiquidSpeechIntegrationTests
```

This check does not download models. Transcribe its WAVs with an independent recognizer and listen to them before claiming wording fidelity or better intonation. Automated ASR and waveform checks cannot establish subjective voice quality.

Initial chunking verification, 2026-11-07 on the local M2 Pro: all 63 package tests passed with the real-model check enabled. The complete app suite passed with 206 tests reported, including 21 skipped. The reproduced English review generated six chunks and 94.82 seconds of combined audio. Independent Whisper Large V3 Turbo recognition, with automatic language detection and translation disabled, recovered its substantive English content; short English and French samples also transcribed correctly. These checks do not qualify broad multilingual quality or subjective intonation.

The signed Dev app was installed under `/Applications`, preserving the previous app in `.build/installed-app-backups`. In its history UI, Stop cancelled synthesis, manual replay reached playback, and starting dictation interrupted playback. The recording was cancelled before transcription or insertion, and the owned Liquid process exited after interruption. Existing Agent Voice settings were preserved. Physical global-hotkey routing and focused-app insertion were not exercised in this check.

Permissive cleanup verification, 2026-11-07: all 73 package tests passed with the real-model check enabled; the full app suite again reported 206 tests, 21 skipped, and no failures. The long English fixture produced a seven-chunk, 100.53-second announced preview, and the Markdown fixture produced 13.59 seconds of audio. Independent Whisper detected English and recovered the preview notice and prose. It misheard the raw filename and command in the Markdown fixture, so exact technical pronunciation and subjective naturalness remain unqualified; the agent's spoken wording is still important. The updated signed Dev app was installed with a backup. One synthetic MCP preparation containing Markdown, a code block, and a long URL was accepted without a correction call. Its original text remained visible in native history, and playback reached the speaking state and completed. No preferences or host configuration were changed.

Second-pass guard/cleanup verification, 2026-11-07: all 78 package tests passed with eight real-model fixtures and cancellation enabled. The full app suite passed with 206 tests reported, including 21 skipped. Long French and mixed-language fixtures both produced eight-chunk previews while keeping French chunks in French and the notice in English. The English cleanup fixture synthesized successfully; independent Whisper detected English and recovered completed/pending status, prose, and the table reference without task markers, HTML tags, or table pipes. Regression tests preserve generic types, comparisons, inline-code literals, shell pipelines, logical OR, and the one-word English context fallback. The whole-response deadline and the language-override policy were not changed. These checks do not qualify broad multilingual pronunciation or subjective intonation.

Installed-app testing must cover the real shortcut, nonactivating control, focused-app insertion, host hook review/activation, concurrent sessions, and audible quality. Automated fixture results do not establish microphone permissions, host trust, or audio audibility.

The evidence below predates automatic playback and is retained as historical runtime/host qualification, not a claim that the new flow has passed those same live checks.

## Runtime pins and measured evidence

- Model: `LiquidAI/LFM3-Audio-2B-GGUF`, revision `02355c1a141e464a064f2ab2c276638dbcb7f38a`.
- `LFM3-Audio-2B-Q4_K_M.gguf`, 1,099,626,016 bytes, SHA-256 `9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2`.
- `mmproj-LFM3-Audio-2B-Q8_0.gguf`, 303,811,840 bytes, SHA-256 `2b6648b1fd48af16aa0877b0592b144d15070783673e038a379fdbc51d40e365`.
- llama.cpp `b11960`, commit `8642541b255bfb5dc39cd351a178be09013a55d6`; arm64 archive SHA-256 `58e5a5e1d7c2bf66cedd9c29e0323f3e570660a70a1e2156d32eed08f4cc1e3c`.
- Refinement stays on `b9627`; audio runtime/dylibs are isolated in `Contents/MacOS/AudioRuntime`.
- MCP Swift SDK `0.12.1`; `0.11.0` failed Swift 6.3.1 concurrency compilation. GRDB remains `7.11.1`.
- `AgentVoiceMCP/InitializationCompatibilityTransport` ignores unsupported non-string experimental client capability metadata during initialization, working around [upstream issue #287](https://github.com/modelcontextprotocol/swift-sdk/issues/287). This helper does not implement those extensions. All tool payloads and non-initialization messages pass through unchanged; the official SDK still owns JSON-RPC, validation, transport framing, and server lifecycle. Remove this narrow adapter when a tested upstream release fixes the decoder.

llama-server's [`/tts`](https://github.com/ggml-org/llama.cpp/blob/8642541b255bfb5dc39cd351a178be09013a55d6/tools/server/README.md) performs synthesis without a separate `llama-tts` executable. ASR sends WAV to `/v1/chat/completions` with an ASR instruction. Recorded `.m4a` is decoded to mono 16 kHz WAV. TTS selects language locally and sends the user’s selected voice. Downloads use checksum verification and staged installation. The bundled LFM Open License terms apply to separately downloaded models.

Measured 2026-11-01 on M2 Pro, 16 GB, macOS 26.6.2, Xcode 26.4.1 / Swift 6.3.1:

| Synthetic fixture | TTS including startup | ASR | Cancellation to observed exit |
| --- | --- | --- | --- |
| Cold, 5.44 s generated speech | 13.29 s | 0.80 s | 0.59 s |
| Qwen3-4B-Instruct-2507 loaded by b9627, 5.28 s speech | 2.18 s | 0.40 s | 0.56 s |

The second run benefits from filesystem/driver caches. Combined sampled RSS was about 5.04 GB at 100 ms intervals; RSS can double-count shared pages and excludes some unified-memory accounting. Refinement was loaded, not generating concurrently. These are viability observations, not release promises across supported Macs.

## Reproduce and extend

```sh
swift test --package-path Packages/AgentVoice
bash script/ensure_audio_runtime.sh .build/liquid-runtime/bin
swift run --package-path Packages/AgentVoice dictaflow-audio-check \
  "$PWD/.build/liquid-runtime/bin" "$PWD/.build/agentvoice-fixtures"
xcodebuild -project DictaFlow.xcodeproj -scheme "DictaFlow Dev" \
  -configuration Debug -derivedDataPath .build/DerivedData test
```

The explicit audio check downloads 1.4 GB of pinned weights, writes a synthetic WAV/report under `.build`, and plays nothing. Unit tests do not download models, request the microphone, insert text, or play sound.

### Stage diagnostics

Agent Voice logs local, content-free timing values under subsystem `com.dictaflow.agentvoice`. Runtime values separate startup/readiness, response headers, bounded body reception, WAV validation, and observed process retirement. Coordinator values cover admission, resource preparation, the playback API call, and waiting for foreground inference resources. Playback API timing does not establish audible onset. Logs contain no rendition text, audio, paths, or credentials and are not transmitted.

To measure six seeded fresh-process TTS runs with existing verified fixtures, without downloads or playback:

```sh
swift run --package-path Packages/AgentVoice dictaflow-audio-check \
  "$PWD/.build/liquid-runtime/bin" "$PWD/.build/agentvoice-fixtures" --tts-benchmark
```

To compare a candidate server setting against the production default in randomized paired order:

```sh
swift run --package-path Packages/AgentVoice dictaflow-audio-check \
  "$PWD/.build/liquid-runtime/bin" "$PWD/.build/agentvoice-fixtures" \
  --tts-benchmark --runs 6 --compare threads10
```

Known variants include `threads4/6/8/10`, `poll100`, `poll0`, `ubatch256`, `batch512`, `ctx2048`, `nowarmup`, `healthpoll20/50/100`, and the kept-set check `poll0_ready20`. `--runs` accepts 1–12, `--seed` overrides the fixed default seed, `--text` overrides the fixed sentence for short-output equivalence checks. Since the efficiency pass, baseline already carries `--poll 0 --poll-batch 0` with 20 ms readiness polling; `poll0`, `healthpoll20`, and `poll0_ready20` now serve as no-op controls.

The report is `tts-benchmark.json` inside the fixture directory. Model files must already exist under its `models` subdirectory. Asset verification occurs before the measured runs. Every run uses a fixed synthetic sentence and seed, so synthesis is byte-identical across runs and variants; the report records the output hash to prove it. Each run, including the baseline, launches with an isolated minimal process environment and the production argument shape plus only its listed extra flags; the baseline does not use the production inherited environment. The API key value is redacted from the recorded config. The report records the server version, model revision, OS, CPU count, physical memory, and the uncontrolled factors (filesystem/driver caches, thermal state and background activity, whole-machine power). It reports per-stage medians only; the run counts are too small for percentile claims. Logs and reports contain no rendition text, audio, paths, or credentials. This is controlled stage comparison, not a battery benchmark or a measure of the next dictation's latency.

Measured 2026-11-02 on M2 Pro, 16 GB. Seeded baseline (6 runs): startup median 0.86 s, header wait median 1.23 s, body 0.046 s, validation 0.001 s, retirement 0.07 s, total 2.22 s, all runs byte-identical (5.28 s audio). Paired comparisons (6 pairs each, randomized order): `threads10` was +0.15 s total / +0.15 s header at the median (5 of 6 pairs worse), `poll100` was +0.30 s total / +0.35 s header (6 of 6 pairs worse). Both candidates were rejected and production keeps its defaults. A verbose one-off startup log showed all 24 language layers plus the output layer offloaded to the MTL0 GPU compute buffer (270.77 MiB vs 20.78 MiB CPU), mmap load mode, and 6 auto-detected threads, so an explicit device override was not tested as a timed candidate. Retirement stays near 0.07 s, which on its own does not justify a playback/retirement overlap change. The existing full-WAV path, immediate retirement, dictation priority, and manual playback authorization remain unchanged. Streaming, warm retention, and other TTS providers are deferred.

Efficiency pass later on 2026-11-02 (same machine, AC power, warm caches): ten more one-variable candidates were measured in seeded randomized pairs with byte-identity checks. `poll0` (`--poll 0 --poll-batch 0`) kept wall time neutral while cutting server CPU seconds per whole cycle from ~2.76 s to ~0.68 s (median of 4+4 runs, separate `getrusage` probe, same 1.70 s wall and identical bytes); single-request sidecars only burned spin-wait with the default poll level. Readiness polling at 20 ms instead of 100 ms saved ~20 ms of startup detection, confirmed in both directions (forward −15/−27 ms, reverse `healthpoll100` +36 ms startup). Both changes were kept: production now passes `--poll 0 --poll-batch 0` and polls readiness every 20 ms. `threads8` gained ~26 ms of inference in 12/12 pairs but cost +23% CPU seconds, so it was rejected for its higher CPU cost (no watts, joules, or thermal headroom were measured); `threads4`, `ubatch256`, `batch512`, `ctx2048`, and `poll0`-for-latency were neutral, and `nowarmup` was 6/6 worse. ASR, short-text synthesis, and cancellation-to-exit all pass under the new defaults with identical bytes. CPU seconds and RSS are reported as measured; they are not watts or joules (`powermetrics` needs root, the Power Profiler template is iOS-only, and device/CUA access was off). A Metal System Trace captured the server in both modes with GPU event counts within 4%, consistent with identical inference work. The 5 s MCP heartbeat (lease UPDATE plus drafts re-read and queue pump per beat) remains a small idle-cost avenue for later work with correctness tests; it was profiled by inspection only.

Historical remaining qualification (before the automatic-playback redesign): authenticated final-completion authority and effective per-attempt configuration guarantees; physical global-hotkey/focus/insertion checks; broad languages, long outputs, thermal/memory pressure and slow cancellation; release signing/notarization. Native hook delivery, competing-Stop correction, and recording-priority interruption (app recording button, capture cancelled before transcription or insertion) have been tested. The dedicated workspace separates connection guidance, the shared Liquid model, and retained renditions with actionable states. Voice customization, model cleanup, and permanent conversation/audio history remain future work.

Installed Dev verification: strict deep signature validation passed; the app launched from `/Applications`, showed both recognition providers and verified Liquid assets, with Whisper still selected. The installed signed helper initialized/listed its five tools, and the installed signed sidecar passed the synthetic TTS/ASR/cancellation check. Agent Voice was enabled temporarily for testing. Starting a brief recording through the app button cancelled active playback; that capture was cancelled before transcription or insertion. After disabling and re-enabling the bridge with the same host/helper still running, the first new prompt received a fresh input ID, prepared its rendition, and completed its native Stop observation. The prior input was shown as interrupted. Physical global-hotkey routing and focused-app insertion were not exercised. The prior Dev app is preserved under `.build/installed-app-backups`.

PR verification on 2026-11-02: all 18 Swift package tests passed. A real-socket regression commits a preparation, loses its reply, reconnects, retrieves the identical request receipt without another mutation, and prepares a fresh prompt. The hosted app suite ran 159 tests: 138 passed, 21 optional fixture tests skipped, and none failed. It covers interruption while synthesis is suspended, rejection of late audio, and explicit retry after synthesis failure. In isolated configurations, Codex 0.166.0 initialized its app-server and returned an empty hook inventory, and Claude Code 2.1.301 connected to the built MCP helper in its health check. These isolated checks do not qualify Claude hooks or automatic playback.


Current verification on 2026-11-02 (this pass): package suite 24 passed; full hosted suite 166 total, 21 skipped, 0 failed after an explicit error fix; targeted AgentVoice suite 10 passed. Installed Dev (latest build): strict deep codesign passed and main-executable/MCP-helper/AudioRuntime hashes match; prior app preserved at `.build/installed-app-backups/20261102-220446-agentvoice-refined/DictaFlow Dev.app`. Installed-app UI check used the explicitly authorized CU fallback (Muse device_list was off), default dark current window: MCP Connections showed the simple Enable toggle on (unchanged), one host setup card with Codex/Claude/Muse/Other switching correctly, Detected visible for 3 CLIs, Advanced config collapsed by default opening valid Muse JSON with separate args/exe path then closed; Models tab showed the Liquid card ready with minimal copy; History Responses showed no raw terminal badges, right-aligned Play/Play-again/Retry with enabled retained old responses; a `git status` query filtered the list then cleared. Play-again on a retained synthetic git-status response showed Generating with Stop; Stop showed Agent speech stopped and Retry enabled. No microphone/insertion/host-config/permission/volume changes. No audio audibility/quality claim (UI state only); light appearance, narrow layout, and VoiceOver were not verified. Dev was left on MCP Connections/Codex, Advanced collapsed, original enable state on. Production TTS flags unchanged: 2 seeded paired candidates lost, no speedup or energy improvement claimed. Astra source-only focused review approved 9/10 with P2 error-lifecycle/P3 replay-docs resolved; not a formal GitHub review. Retained terminal responses can still reach the queue cap.

Correctness pass on 2026-11-02 (this change): package suite 32 passed; full hosted suite 169 total, 21 skipped, 0 failed; targeted AgentVoice 13 plus HostSetup 2 passed. Synthetic TTS/ASR/cancel with existing verified assets and no downloads or playback: TTS 2.32 s, ASR 0.34 s exact transcript, cancel-to-exit 0.03 s, runtime b11960. New coverage: unknown-outcome prompt retry returns `new_prompt_required` without resend or valid-attachment retirement (adapter and real-socket), committed receipts still return the original reply; ASR input cap 2 min/8 MiB with metadata preflight and runtime guard, missing/invalid/overlimit tested without downloads or microphone; retained terminal replay respects the queue cap through Play with playback-scoped errors; expired Play refreshes eligibility with no audio attempt. Draftless terminal rows now set `host_closed` consistently. Production keeps `--poll 0 --poll-batch 0`, 20 ms readiness, and pinned b11960; no battery, watts, or global-optimality claim (`powermetrics` needs root, device access off, no app install in this pass). An independent final reviewer will judge the efficiency and correctness changes; no prior review covered this change. Not every P2 test gap is closed: the real-socket prompt accepted-then-lost case remains a nonblocking followup; current coverage is the prepare-committed socket regression plus unit prompt-receipt logic.

## Diagnosis of the initial live-test failure

Two independent faults caused the earlier failure, without requiring a dictation-engine redesign:

1. **SDK interoperability:** Codex sends `experimental = {"codex/auth-change": {}}`. The SDK decoded it as `[String: String]`, failing before hooks or tools could run. The compatibility transport above fixes that boundary, with an exact captured Codex initialize packet covered by a real-helper regression test.
2. **Test configuration:** CLI `-c` paths were built with quoted segments. In the tested CLI these became literal keys rather than the intended server/project keys, leaving the project hooks undiscovered. File-based TOML and CLI dotted-key parsing must not be assumed identical. Corrected per-process overrides and exact-definition trust were verified with `hooks/list`, showing all three native MCP hooks enabled and trusted. No global configuration or persistent trust was changed.

Use normal project `.codex/config.toml` and `.codex/hooks.json` files for setup, then inspect `/hooks` and review/trust the exact definitions. A connected MCP server alone does not prove hook activation. The automated diagnostic harness uses the app-server `hooks/list` API and per-process trust of the exact test hashes; it does not need Terminal UI access, a trust bypass, or a custom agent host.

Additional fixes retire stale ownership, preserve unknown-outcome receipts, document rendition replacement after continuation, surface rejected observations, and clear stale “Speaking” status after local interruption. Hosted unit tests skip opening the real Agent Voice store/socket; their coordinators use isolated fixtures instead.

The real continuation test used a second Stop hook that requested a branch-protection caveat once. The agent read the existing draft identity/revision and replaced it at revision 2 before its final clean answer. DictaFlow remained `awaitingCompletion` after Stop, with no automatic queue admission. This demonstrates working revision handling, not authorization to play after every Stop.
