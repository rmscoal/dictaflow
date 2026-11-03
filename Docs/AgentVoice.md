# Agent Voice foundation

Agent Voice has a dedicated sidebar destination with MCP Connections, Models, and History tabs. MCP Connections is the landing page. Dictation keeps its existing press, release, speak, press-again-to-stop flow. The original agent submits a conversational rendition through MCP before its clean written answer. TurnEcho inspired this workflow; no TurnEcho code, Python runtime, tags, or transcript scraping is used.

## Qualification

The two decisions remain independent:

| Capability | Current result |
| --- | --- |
| Clean MCP submission and lifecycle observations | Verified with real Codex 0.166.0 native prompt/Stop/Interrupt hooks and its real model |
| Host-authorized automatic playback | **Unqualified and disabled** |
| Liquid local TTS and ASR | Pinned model passed a synthetic English round trip on M2 Pro, 16 GB |
| Foreground priority and queue admission | Fixtures cover recording, playback, and late synthesis; installed-app recording-button interruption verified; physical hotkey/focus/insertion checks remain manual |

Codex CLI 0.166.0 was exercised through its supported app-server API, using the installed Dev helper directly. Native prompt context injection, model preparation before a clean written answer, Stop observation, native interruption, and a competing Stop hook requiring a revision were verified. Claude Code 2.1.301 is installed but has not been qualified. Automatic completion authority remains a separate question from a working hook workflow.

The [Codex hook documentation](https://learn.chatgpt.com/docs/hooks) describes Stop and previous continuation state, but provides no documented aggregate decision for the current attempt, authenticated tool-call origin, or stable effective-hook-configuration snapshot for that attempt. Consequently this implementation contains **no automatic authorization API**, exclusive-stop mode, or timer workaround. A model call to `on_stop` can only enter `awaitingCompletion`.

An automatic-playback adapter must first prove trustworthy lifecycle origin and final acceptance for the exact completion attempt, including another hook asking for continuation. Configuration rescans and attachment epochs are not proof. Failure of that experiment does not reject Liquid recognition, synthesis, or clean MCP submission.

## Code and ownership

- `Packages/AgentVoice`: versioned contracts, GRDB store, Unix bridge, Liquid assets/runtime, MCP executable, diagnostics, and tests.
- `Services/AgentVoice/AgentVoiceCoordinator.swift`: app-owned queue runner, player, foreground leases, status, and enable/disable control.
- `DictaFlowAppState`: existing recording behavior with additive leases across recording, ASR, refinement, and insertion.
- `WhisperConfiguration` keeps its name/key and saved Whisper preferences for compatibility, adding a recognition provider.
- `WhisperTranscriptionResult` keeps the history format. Liquid results explicitly have provider `liquid` and no Whisper model.
- The Models tab Liquid badge (`provider-liquid`) is the Liquid mark from [Lobe Icons](https://github.com/lobehub/lobe-icons), covered by the shared MIT attribution in `Resources/ThirdParty/provider-icons-LICENSE`.

The app owns models and a separate `AgentVoice/voice.sqlite` store under its Application Support identity. Dev/release have separate stores, installation IDs, model directories, and socket paths. The Unix bridge checks peer UID and private directory/socket permissions. This authenticates the OS user, **not** whether a host hook or model originated a call.

Only submitted renditions/control metadata are stored. Complete prompts, chat transcripts, and generated audio history are not retained. Unfinished work becomes interrupted on app restart and never automatically resumes.

## Setup

1. Build/install the Dev app and enable the local connection in Agent Voice > MCP Connections.
2. Copy the displayed executable and arguments into the host's stdio MCP configuration. Keep the installation ID stable.
3. Add observation hooks where supported, using the example below. No global host configuration is changed automatically.
4. The prompt hook supplies session/input IDs and conversational writing instructions. The agent calls `prepare_spoken_response` before its ordinary written answer.
5. Stop records an observation. Explicitly press Play on a prepared rendition in Agent Voice > History. History lists retained rendition text, not saved audio; Play generates speech again. Press Play again on an interrupted or superseded row while its text is retained. Expired or deleted renditions are unavailable, and nothing resumes automatically. Retention remains bounded by the existing 24-hour retry window.
6. Starting dictation immediately stops active speech. Valid jobs can queue during recording; synthesis/playback wait for foreground leases to finish.

Example Codex hooks for an already-connected MCP server named `dictaflow`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{
      "type": "mcp_tool", "server": "dictaflow", "tool": "on_user_prompt_submit",
      "input": {"session_id": "${session_id}", "turn_id": "${turn_id}"}, "timeout": 2
    }]}],
    "Stop": [{"hooks": [{
      "type": "mcp_tool", "server": "dictaflow", "tool": "on_stop",
      "input": {"session_id": "${session_id}", "turn_id": "${turn_id}"}, "timeout": 2
    }]}],
    "Interrupt": [{"hooks": [{
      "type": "mcp_tool", "server": "dictaflow", "tool": "on_interrupt",
      "input": {"session_id": "${session_id}", "turn_id": "${turn_id}"}, "timeout": 2
    }]}]
  }
}
```

This configuration shape has been exercised in real Codex turns. The prompt hook returns documented `hookSpecificOutput.additionalContext` JSON, also as structured MCP content. Stop/Interrupt never return blocking or continuation decisions. Errors leave the written conversation working. Hosts without native hooks may call these tools explicitly through instructions without gaining automatic playback authority.

Native turn mapping is process-local. Reconnecting requires a new prompt observation; prior unfinished speech is interrupted. Normal tool traces remain visible in the host.

## Contract v1

| Tool | Inputs and behavior |
| --- | --- |
| `on_user_prompt_submit` | Native `session_id`, `turn_id`; creates app input ID and writing instructions, supersedes prior unfinished speech |
| `prepare_spoken_response` | `session_id`, app `input_id`, UUID `request_id`, `text`; optional `replaces_draft_id` and `expected_revision` |
| `on_stop` | Native session/turn mapping or explicit input; observation only; absent draft closes as `skippedMissingDraft` |
| `on_interrupt` | Cancels that input's speech, without cancelling the agent |
| `get_speech_status` | Explicit session/input/request IDs; reads current state |

Logical identity is app identity + installation ID + host kind + native session ID. Connection identity is separate: attachment ID, monotonic epoch, one writer, 30-second lease renewed every five seconds. Simultaneous attachments fail. Disconnect or a new attachment after lease expiry closes prior unfinished work. Stale writers cannot mutate it.

One current draft exists per input, starting at revision 1. Replacement requires the current draft ID/revision. Stop observation does not commit it; explicit corrections remain possible before admission. Queue admission freezes text. Missing/closed/expired input IDs cannot be recreated by preparation. A new prompt cancels prior unfinished speech in that session.

The raw bridge envelope includes version, request UUID, issued time, logical session, attachment, operation, and optional input/draft data. Identical retries retrieve durable receipts; changed payload conflicts. Receipt/input retention is 24 hours from initial acceptance/creation, without extension by retries. Session epoch tombstones remain. Issued timestamps bound expired raw-request replays, and unknown input IDs remain inadmissible after purge.

The helper retains original requests during its lifetime for unknown-outcome timeout retries. Transport failure retires every attachment and native-turn mapping immediately. A new prompt whose complete frame was never sent may reconnect and retry once; a stale-attachment rejection may likewise reattach and deliver that new prompt once. An unknown outcome is never blindly resubmitted with changed identity. Identical receipt retries retain the original envelope, including its timestamp and retired attachment. If that envelope has no receipt and its attachment is stale, the helper returns `new_prompt_required` without reattaching, resending, or retiring the current valid attachment; the fresh turn stays usable. A stale reply at one instant does not prove the original will never commit, and a changed-attachment resend would conflict with that receipt or supersede fresher work. After a helper restart, begin a new prompt cycle. Raw identical stale-attachment receipt retrieval is read-only and does not renew ownership. Rejected Stop/Interrupt observations return an observable tool error without asking the host to continue or block.

Explicit user Play creates a fresh playback-attempt ID from retained text and closes host preparation, replacement, and Stop; fail-safe interrupt and status reads remain. It does not manufacture completion evidence or reopen host input. A user retry after an authorized completion/failure regenerates speech; reconnecting never triggers it. Exact audio replay/session history is deferred.

## Audio and resource policy

Recording state becomes idle before ASR ends, so it is not the sole audio guard. Foreground leases cover permission/startup, capture, ASR, refinement, and insertion. History inference and Whisper warmup also take priority. Acquisition synchronously stops the player, cancels speech, and invalidates its generation. Late audio cannot pass playback checks.

Foreground inference waits for the owned Liquid process to exit. Termination escalates to SIGKILL after a provisional 750 ms, then observes exit for another 500 ms. It targets only the owned audio sidecar. Process exit does not prove immediate reclamation of all OS/Metal allocations. If exit remains unobserved, inference fails with status and retains the capture.

Before TTS the app unloads idle Whisper and stops idle refinement. Liquid stops after synthesis before playback. This favors memory predictability and recording priority over keeping every model warm. Queue scheduling preserves session order and alternates sessions when possible.

Provisional bounds: 8,000 characters; five pending/session, 50 globally; five-minute prepared-rendition lifetime from first preparation, without extension by replacements; five-minute queue expiry from authorized admission, checked before synthesis/playback; 60-second synthesis budget; 12 MiB output; decoded audio under 120 seconds. Liquid ASR input is capped at 2 minutes or 8 MiB, checked from recording metadata before the full decode and again before the base64 POST. The cap is estimated from the pinned runtime (no retained raw token probe; an estimate, not a reproducible measurement): about 12.5 prompt tokens per second plus 20 framing tokens, --ctx-size 4096 with max_tokens 2048 reserved, leaves about 162 s; 120 s keeps a 528-token margin and a normal 150 wpm transcript inside max_tokens, and 8 MiB covers 120 s of 16 kHz mono float32. Longer clips fail explicitly with the recording kept for a Whisper or shorter retry; they are never truncated or auto-switched. A long-running agent turn does not consume its rendition lifetime before preparation. Oversized output fails explicitly without trimming text. Generation validates before playback. Local connect/request deadlines are 100/700 ms; a timeout may have an unknown outcome, so retry the identical request. Agents are instructed to finish their written answer without repair loops. Expired storage is purged on launch and subsequent access.

WebSockets, realtime transcription, streaming playback, automatic prompt submission, Liquid conversational reasoning, and separate rewriting models are outside this integration.

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

Remaining qualification: authenticated final-completion authority and effective per-attempt configuration guarantees; physical global-hotkey/focus/insertion checks; broad languages, long outputs, thermal/memory pressure and slow cancellation; release signing/notarization. Native hook delivery, competing-Stop correction, and recording-priority interruption (app recording button, capture cancelled before transcription or insertion) have been tested. The dedicated workspace separates connection guidance, the shared Liquid model, and retained renditions with actionable states. Voice customization, model cleanup, and permanent conversation/audio history remain future work.

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
