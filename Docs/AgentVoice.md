# Agent Voice

Agent Voice provides automatic, interruptible local speech for connected agent sessions. The originating agent writes a conversational rendition through MCP before its clean written answer. Liquid synthesizes that rendition locally. Dictation and optional text refinement remain local and take priority over agent speech. The external coding host retains its own inference arrangement.

## User experience

Enable Agent Voice and download the verified Liquid model. Under MCP Connections, choose **Speak automatically** or **Show Play control**. Automatic mode admits the current eligible rendition when the host reports Stop. Manual mode retains the response and shows a compact Play control.

The floating control identifies the speaking session and provides Stop and Dictate. It does not take keyboard focus from the target app. The existing dictation shortcut also interrupts speech. Interruption is a deliberate button or shortcut action; DictaFlow does not listen continuously for speech over the agent.

Stop persists suppression for the interrupted interaction. Delayed Stop observations and corrections cannot automatically make it speak again. Explicit Play remains possible, and a new user turn is independently eligible. Dictation holds audio priority through recording, transcription, refinement, and insertion. Responses arriving during that work wait in the queue. Stopping speech does not cancel the coding agent.

History shows interactions, retained prompt text when supplied, each spoken revision, playback attempts, and relevant events. Search matches session identities, prompts, and renditions. Play regenerates speech from the selected text; generated audio is not retained for exact replay. Deleting an interaction removes its retained speech history and cancels its active attempts. Ordinary dictation history remains separate.

## Lifecycle contract

1. `on_user_prompt_submit` creates an interaction and returns its internal input ID plus spoken-rendition instructions.
2. The model calls `prepare_spoken_response` with conversational text. This never starts speech by itself.
3. The model produces its written answer.
4. `on_stop` makes the current rendition eligible. DictaFlow applies the app's playback preference, suppression, freshness, and queue limits.
5. An automatic attempt is created at most once for that rendition. Duplicate Stop delivery does not replay it.
6. A corrected preparation creates a new immutable revision and supersedes active speech for older revisions. The new revision waits for a fresh Stop. Stop-before-preparation does not authorize a later rendition.

The [Codex hook contract](https://learn.chatgpt.com/docs/hooks) allows another Stop hook to request continuation. Therefore this feature provides interruptible, best-effort playback of a completion candidate, not proof that every host check has accepted a final answer. A revision may have been partly heard before a correction arrives. IDs and local timestamps do not prove source ordering. Native event/turn identities are used when available; a host without a turn identity can address its current session input, with correspondingly weaker late-event correlation.

The bridge authenticates the local OS user, not whether a tool invocation originated from a model or a host hook. Playback consent is the app setting; MCP callers cannot change it. Lifecycle messages still require a valid session attachment. No timer is presented as proof of finality.

## Setup and host boundaries

MCP Connections registers the bundled helper for the chosen host. Codex and Claude Code lifecycle setup uses their user-level configuration; review the exact hooks in the host when prompted and start a new session. Existing unrelated configuration must be preserved. A configured server entry alone does not prove that a host has reviewed and activated hooks.

Codex setup also pre-approves DictaFlow's own tools with `default_tools_approval_mode = "approve"` under `[mcp_servers.dictaflow]` in `~/.codex/config.toml`, so sessions are not interrupted by approval prompts for the speech tools. The key is only added when absent; an existing value is never overwritten. If setup edits the file, it re-runs `codex mcp list` as a parse check and restores the original bytes on failure, so a failed run never strands a broken config. Manual setup carries the same line. This mirrors what Codex writes for a manual Always-allow, but as one server default covering every DictaFlow tool, including the read-only status query. When pasting the manual snippet, if the `[mcp_servers.dictaflow]` table already exists, add only the missing lines; duplicating the table breaks the file.

Codex's hooks can supply native session and turn IDs. Claude Code has different event fields and requires its own configuration. Other MCP hosts need a lifecycle integration or manual playback; do not assume they implement Codex hooks. Lifecycle setup and supported versions must be checked using isolated host fixtures before claiming end-to-end support.

Example Codex hooks for an MCP server named `dictaflow`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{
      "type": "mcp_tool", "server": "dictaflow", "tool": "on_user_prompt_submit",
      "input": {"session_id": "${session_id}", "turn_id": "${turn_id}", "prompt": "${prompt}"},
      "timeout": 2, "statusMessage": "DictaFlow: Agent Voice"
    }]}],
    "Stop": [{"hooks": [{
      "type": "mcp_tool", "server": "dictaflow", "tool": "on_stop",
      "input": {"session_id": "${session_id}", "turn_id": "${turn_id}"},
      "timeout": 2, "statusMessage": "DictaFlow: Agent Voice"
    }]}],
    "Interrupt": [{"hooks": [{
      "type": "mcp_tool", "server": "dictaflow", "tool": "on_interrupt",
      "input": {"session_id": "${session_id}", "turn_id": "${turn_id}"},
      "timeout": 2, "statusMessage": "DictaFlow: Agent Voice"
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

Foreground inference waits for the owned Liquid process to exit. Termination escalates after a bounded grace period. The process belongs to DictaFlow; unrelated inference processes are not stopped. Before TTS, idle Whisper/refinement resources are released. Liquid stops after synthesis before playback.

Current limits: 8,000 rendition characters; five pending jobs per session and 50 globally; a five-minute automatic eligibility window for each prepared revision; five-minute queued/synthesizing attempt lifetime; 60-second synthesis budget; 12 MiB WAV output; playback shorter than 120 seconds. Liquid ASR input is limited to two minutes or 8 MiB. Oversized input/output fails explicitly. Long-form chunking and streaming are not implemented.

The production TTS payload currently uses English and a female voice. Other languages, mixed-language quality, and voice customization require separate validation. No new cloud inference, telemetry, or remote transcription is introduced.

## Verification

Run `swift test --package-path Packages/AgentVoice` for contract, storage, migration, identity, lifecycle, and transport tests. Hosted `AgentVoiceTests` cover automatic playback, duplicate Stop during playback, revisions waiting for fresh Stop, persistent user suppression, manual mode, deletion, foreground priority, and late synthesis rejection. See `Tests/README.md` for app test commands.

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

llama-server's [`/tts`](https://github.com/ggml-org/llama.cpp/blob/8642541b255bfb5dc39cd351a178be09013a55d6/tools/server/README.md) performs synthesis without a separate `llama-tts` executable. ASR sends WAV to `/v1/chat/completions` with an ASR instruction. Recorded `.m4a` is decoded to mono 16 kHz WAV. Initial TTS uses English/female; multilingual quality and voice controls remain future work. Downloads use checksum verification and staged installation. The bundled LFM Open License terms apply to separately downloaded models.

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
