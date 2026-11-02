# Agent Voice foundation

Initial engine integration with small preview controls in General settings. Dictation keeps its existing press, release, speak, press-again-to-stop flow. The original agent submits a conversational rendition through MCP before its clean written answer. TurnEcho inspired this workflow; no TurnEcho code, Python runtime, tags, or transcript scraping is used.

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

The app owns models and a separate `AgentVoice/voice.sqlite` store under its Application Support identity. Dev/release have separate stores, installation IDs, model directories, and socket paths. The Unix bridge checks peer UID and private directory/socket permissions. This authenticates the OS user, **not** whether a host hook or model originated a call.

Only submitted renditions/control metadata are stored. Complete prompts, chat transcripts, and generated audio history are not retained. Unfinished work becomes interrupted on app restart and never automatically resumes.

## Setup

1. Build/install the Dev app and enable the MCP connection in General settings.
2. Copy the displayed executable and arguments into the host's stdio MCP configuration. Keep the installation ID stable.
3. Add observation hooks where supported, using the example below. No global host configuration is changed automatically.
4. The prompt hook supplies session/input IDs and conversational writing instructions. The agent calls `prepare_spoken_response` before its ordinary written answer.
5. Stop records an observation. In this preview, explicitly press Play on a prepared rendition in General settings.
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

The helper retains original requests during its lifetime for unknown-outcome timeout retries. Transport failure retires every attachment and native-turn mapping immediately. A new prompt whose complete frame was never sent may reconnect and retry once; a stale-attachment rejection may likewise reattach and deliver that new prompt once. An unknown outcome is never blindly resubmitted with changed identity. Identical receipt retries retain the original envelope, including its timestamp and retired attachment. After a helper restart, begin a new prompt cycle. Raw identical stale-attachment receipt retrieval is read-only and does not renew ownership. Rejected Stop/Interrupt observations return an observable tool error without asking the host to continue or block.

Explicit user Play creates a fresh playback-attempt ID from retained text and closes host mutations. It does not manufacture completion evidence or reopen host input. A user retry after an authorized completion/failure regenerates speech; reconnecting never triggers it. Exact audio replay/session history is deferred.

## Audio and resource policy

Recording state becomes idle before ASR ends, so it is not the sole audio guard. Foreground leases cover permission/startup, capture, ASR, refinement, and insertion. History inference and Whisper warmup also take priority. Acquisition synchronously stops the player, cancels speech, and invalidates its generation. Late audio cannot pass playback checks.

Foreground inference waits for the owned Liquid process to exit. Termination escalates to SIGKILL after a provisional 750 ms, then observes exit for another 500 ms. It targets only the owned audio sidecar. Process exit does not prove immediate reclamation of all OS/Metal allocations. If exit remains unobserved, inference fails with status and retains the capture.

Before TTS the app unloads idle Whisper and stops idle refinement. Liquid stops after synthesis before playback. This favors memory predictability and recording priority over keeping every model warm. Queue scheduling preserves session order and alternates sessions when possible.

Provisional bounds: 8,000 characters; five pending/session, 50 globally; five-minute prepared-rendition lifetime from first preparation, without extension by replacements; five-minute queue expiry from authorized admission, checked before synthesis/playback; 60-second synthesis budget; 12 MiB output; decoded audio under 120 seconds. A long-running agent turn does not consume its rendition lifetime before preparation. Oversized output fails explicitly without trimming text. Generation validates before playback. Local connect/request deadlines are 100/700 ms; a timeout may have an unknown outcome, so retry the identical request. Agents are instructed to finish their written answer without repair loops. Expired storage is purged on launch and subsequent access.

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

Remaining qualification: authenticated final-completion authority and effective per-attempt configuration guarantees; physical global-hotkey/focus/insertion checks; broad languages, long outputs, thermal/memory pressure and slow cancellation; release signing/notarization. Native hook delivery and competing-Stop correction have now been tested. Recording-priority interruption has also been observed in the installed app using its recording button, with the brief test capture cancelled before transcription or insertion. UI work can build on coordinator state/actions without redesigning recording. Dedicated connection/queue/error views, voice settings, model cleanup, and optional conversation history follow later.

Installed Dev verification: strict deep signature validation passed; the app launched from `/Applications`, showed both recognition providers and verified Liquid assets, with Whisper still selected. The installed signed helper initialized/listed its five tools, and the installed signed sidecar passed the synthetic TTS/ASR/cancellation check. Agent Voice was enabled temporarily for testing. Starting a brief recording through the app button cancelled active playback; that capture was cancelled before transcription or insertion. After disabling and re-enabling the bridge with the same host/helper still running, the first new prompt received a fresh input ID, prepared its rendition, and completed its native Stop observation. The prior input was shown as interrupted. Physical global-hotkey routing and focused-app insertion were not exercised. The prior Dev app is preserved under `.build/installed-app-backups`.

PR verification on 2026-11-02: all 18 Swift package tests passed. A real-socket regression commits a preparation, loses its reply, reconnects, retrieves the identical request receipt without another mutation, and prepares a fresh prompt. The hosted app suite ran 159 tests: 138 passed, 21 optional fixture tests skipped, and none failed. It covers interruption while synthesis is suspended, rejection of late audio, and explicit retry after synthesis failure. In isolated configurations, Codex 0.166.0 initialized its app-server and returned an empty hook inventory, and Claude Code 2.1.301 connected to the built MCP helper in its health check. These isolated checks do not qualify Claude hooks or automatic playback.


## Diagnosis of the initial live-test failure

Two independent faults caused the earlier failure, without requiring a dictation-engine redesign:

1. **SDK interoperability:** Codex sends `experimental = {"codex/auth-change": {}}`. The SDK decoded it as `[String: String]`, failing before hooks or tools could run. The compatibility transport above fixes that boundary, with an exact captured Codex initialize packet covered by a real-helper regression test.
2. **Test configuration:** CLI `-c` paths were built with quoted segments. In the tested CLI these became literal keys rather than the intended server/project keys, leaving the project hooks undiscovered. File-based TOML and CLI dotted-key parsing must not be assumed identical. Corrected per-process overrides and exact-definition trust were verified with `hooks/list`, showing all three native MCP hooks enabled and trusted. No global configuration or persistent trust was changed.

Use normal project `.codex/config.toml` and `.codex/hooks.json` files for setup, then inspect `/hooks` and review/trust the exact definitions. A connected MCP server alone does not prove hook activation. The automated diagnostic harness uses the app-server `hooks/list` API and per-process trust of the exact test hashes; it does not need Terminal UI access, a trust bypass, or a custom agent host.

Additional fixes retire stale ownership, preserve unknown-outcome receipts, document rendition replacement after continuation, surface rejected observations, and clear stale “Speaking” status after local interruption. Hosted unit tests skip opening the real Agent Voice store/socket; their coordinators use isolated fixtures instead.

The real continuation test used a second Stop hook that requested a branch-protection caveat once. The agent read the existing draft identity/revision and replaced it at revision 2 before its final clean answer. DictaFlow remained `awaitingCompletion` after Stop, with no automatic queue admission. This demonstrates working revision handling, not authorization to play after every Stop.
