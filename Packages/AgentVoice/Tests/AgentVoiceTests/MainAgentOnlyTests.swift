import AgentVoice
import AgentVoiceMCP
import Foundation
import MCP
import Testing

/// Main-agent-only voice: child/nested agents must not open interactions,
/// submit renditions, admit playback, or cancel parent speech. The PreToolUse
/// guard hook blocks direct child model calls from host-supplied identity;
/// the adapter rejects hook-forwarded child identity before any store
/// contact. Independent top-level sessions stay allowed.
struct MainAgentOnlyTests {
    // MARK: - Adapter child filter

    @Test func childIdentityIsDeniedOnEveryToolWithoutStoreContact() async throws {
        for host in ["claude", "muse"] {
            for tool in ["on_user_prompt_submit", "prepare_spoken_response", "skip_spoken_response", "on_stop",
                         "on_interrupt", "get_speech_status"] {
                let client = CountingBridge()
                let adapter = VoiceAdapter(client: client, installationID: UUID(), host: host)
                var arguments: [String: Value] = ["session_id": "session", "agent_id": "agent-child-1"]
                if tool == "prepare_spoken_response" || tool == "get_speech_status" {
                    arguments["request_id"] = .string(UUID().uuidString)
                }
                if tool == "prepare_spoken_response" {
                    arguments["input_id"] = .string(UUID().uuidString)
                    arguments["text"] = "Child speech."
                }
                let reply = try await adapter.call(name: tool, arguments: arguments)
                #expect(!reply.accepted)
                #expect(reply.code == "child_agent_denied")
                #expect(reply.inputID == nil && reply.attemptID == nil)
                #expect(await client.sent.isEmpty,
                        "\(tool) on \(host) must not attach, mutate, or admit anything.")
            }
        }
    }

    @Test func rootCallsWithoutIdentityAreForwarded() async throws {
        let client = CountingBridge()
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "claude")
        _ = try await adapter.call(name: "on_stop", arguments: ["session_id": "session"])
        #expect(await client.sent.map(\.operation) == [.attach, .stop])
    }

    @Test func rootCustomAgentTypeWithoutAgentIDIsAllowed() async throws {
        // A root `--agent` session sets agent_type with no agent_id. Type
        // alone never proves a child, so the call must go through.
        let client = CountingBridge()
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "claude")
        _ = try await adapter.call(name: "on_stop", arguments: ["session_id": "session",
                                                                 "agent_type": "Explore"])
        #expect(await client.sent.map(\.operation) == [.attach, .stop])
    }

    @Test func emptyAndUnsubstitutedIdentityAreMainSession() async throws {
        for agentID in ["", "${agent_id}"] {
            let client = CountingBridge()
            let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "claude")
            _ = try await adapter.call(name: "on_stop",
                                       arguments: ["session_id": "session",
                                                   "agent_id": .string(agentID)])
            #expect(await client.sent.map(\.operation) == [.attach, .stop],
                    "agent_id \(agentID.debugDescription) must be treated as the main session.")
        }
    }

    @Test func malformedAgentIDFailsLoudlyWithoutStoreContact() async {
        let client = CountingBridge()
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "claude")
        await #expect(throws: VoiceError.self) {
            try await adapter.call(name: "on_stop",
                                   arguments: ["session_id": "session", "agent_id": .int(7)])
        }
        #expect(await client.sent.isEmpty)
    }

    @Test func deniedChildDoesNotPoisonRequestIDForMain() async throws {
        // The denial happens before any receipt reservation, so the main
        // agent can still use the same request envelope afterwards.
        let requestID = UUID().uuidString
        let client = CountingBridge()
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "claude")
        let denied = try await adapter.call(name: "on_stop",
                                            arguments: ["session_id": "session",
                                                        "agent_id": "agent-child-1",
                                                        "request_id": .string(requestID)])
        #expect(!denied.accepted)
        let allowed = try await adapter.call(name: "on_stop",
                                             arguments: ["session_id": "session",
                                                         "request_id": .string(requestID)])
        #expect(allowed.accepted)
        #expect(await client.sent.map(\.operation) == [.attach, .stop])
    }

    @Test func codexAndOtherHostsIgnoreAgentID() async throws {
        // Model arguments cannot claim a role; Codex uses transport metadata.
        for host in ["codex", "other", "fixture"] {
            let client = CountingBridge()
            let adapter = VoiceAdapter(client: client, installationID: UUID(), host: host)
            _ = try await adapter.call(name: "on_stop",
                                       arguments: ["session_id": "session",
                                                   "agent_id": "agent-child-1"],
                                       metadata: ["threadId": "session", "sessionId": "session"])
            #expect(await client.sent.map(\.operation) == [.attach, .stop],
                    "Host \(host) must keep its existing behavior.")
        }
    }

    private let voiceTools = ["on_user_prompt_submit", "prepare_spoken_response", "skip_spoken_response", "on_stop",
                              "on_interrupt", "get_speech_status"]

    private func codexArguments(session: String = "root") -> [String: Value] {
        ["session_id": .string(session), "turn_id": "turn", "agent_id": "",
         "input_id": .string(UUID().uuidString), "request_id": .string(UUID().uuidString),
         "text": "A response.", "threadId": .string(session), "sessionId": .string(session)]
    }

    @Test func codexChildCannotUseAnyToolOrSpoofSessionArguments() async throws {
        for tool in voiceTools {
            for session in ["root", "child", "unrelated"] {
                let client = CountingBridge()
                let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "codex")
                let reply = try await adapter.call(name: tool, arguments: codexArguments(session: session),
                                                  metadata: ["threadId": "child", "sessionId": "root", "callId": "call"])
                #expect(reply.code == "child_agent_denied")
                #expect(!reply.accepted)
                #expect(await client.sent.isEmpty)
            }
        }
    }

    @Test func codexMissingMalformedAndOldDirectIdentityNeverContactsStore() async throws {
        let identities: [[String: Value]?] = [
            nil, [:], ["threadId": "root"], // hook-shaped metadata cannot prepare/status
            ["threadId": "root", "callId": "old-call"],
            ["threadId": "root", "sessionId": .null],
            ["threadId": "root", "sessionId": ""],
            ["threadId": .int(1), "sessionId": "root"],
            ["threadId": "", "sessionId": "root"]
        ]
        for metadata in identities {
            for tool in voiceTools {
                if metadata == ["threadId": "root"],
                   ["on_user_prompt_submit", "on_stop", "on_interrupt"].contains(tool) { continue }
                let client = CountingBridge()
                let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "codex")
                let reply = try await adapter.call(name: tool, arguments: codexArguments(), metadata: metadata)
                #expect(!reply.accepted)
                #expect(reply.code == "caller_identity_missing")
                #expect(await client.sent.isEmpty)
            }
        }
    }

    @Test func codexRootMetadataAllowsAllToolsAndIndependentSessions() async throws {
        let client = CountingBridge()
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "codex")
        for session in ["root-a", "root-b"] {
            for tool in voiceTools {
                let reply = try await adapter.call(name: tool, arguments: codexArguments(session: session),
                                                  metadata: ["threadId": .string(session), "sessionId": .string(session)])
                #expect(reply.accepted)
            }
        }
        let sent = await client.sent
        #expect(sent.filter { $0.operation == .attach }.count == 2)
        #expect(sent.filter { $0.operation != .attach }.count == 12)
    }

    @Test func codexLifecycleHooksUseOwningThreadBeforeAnyStoreContact() async throws {
        for tool in ["on_user_prompt_submit", "on_stop", "on_interrupt"] {
            let client = CountingBridge()
            let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "codex")
            let args = codexArguments()
            let child = try await adapter.call(name: tool, arguments: args, metadata: ["threadId": "child"])
            #expect(child.code == "child_agent_denied")
            #expect(await client.sent.isEmpty)
            // The same request remains usable: a child did not reserve a receipt.
            let root = try await adapter.call(name: tool, arguments: args, metadata: ["threadId": "root"])
            #expect(root.accepted)
            #expect(await client.sent.count == 2)
        }
    }

    @Test func codexRootCannotAddressAnotherSession() async throws {
        let client = CountingBridge()
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "codex")
        let reply = try await adapter.call(name: "on_interrupt", arguments: codexArguments(session: "other"),
                                          metadata: ["threadId": "root", "sessionId": "root"])
        #expect(reply.code == "session_identity_mismatch")
        #expect(await client.sent.isEmpty)
    }

    // MARK: - PreToolUse guard responses

    private func denyPayload(_ text: String?) throws -> [String: Any] {
        let data = try #require(text.map { Data($0.utf8) })
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["hookSpecificOutput"] as? [String: Any])
    }

    @Test func claudeChildIsDeniedAndMainIsSilent() throws {
        let child = Data(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"mcp__dictaflow__prepare_spoken_response","agent_id":"agent-1","agent_type":"Explore"}"#.utf8)
        let output = try denyPayload(HookGuard.response(event: "PreToolUse", host: "claude", stdin: child))
        #expect(output["hookEventName"] as? String == "PreToolUse")
        #expect(output["permissionDecision"] as? String == "deny")
        #expect((output["permissionDecisionReason"] as? String)?.isEmpty == false)

        let main = Data(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"mcp__dictaflow__prepare_spoken_response"}"#.utf8)
        #expect(HookGuard.response(event: "PreToolUse", host: "claude", stdin: main) == nil)
    }

    @Test func claudeRootAgentTypeAndMalformedInputFailOpen() throws {
        let rootAgent = Data(#"{"hook_event_name":"PreToolUse","session_id":"s","agent_type":"Explore"}"#.utf8)
        #expect(HookGuard.response(event: "PreToolUse", host: "claude", stdin: rootAgent) == nil)
        #expect(HookGuard.response(event: "PreToolUse", host: "claude", stdin: Data("not json".utf8)) == nil)
        #expect(HookGuard.response(event: "PreToolUse", host: "claude", stdin: Data()) == nil)
        let emptyID = Data(#"{"hook_event_name":"PreToolUse","agent_id":""}"#.utf8)
        #expect(HookGuard.response(event: "PreToolUse", host: "claude", stdin: emptyID) == nil)
    }

    @Test func museThreadEqualityDecidesAndMissingIdentityDeniesLoudly() throws {
        let stdin = Data(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"mcp__dictaflow__on_stop"}"#.utf8)
        #expect(HookGuard.response(event: "PreToolUse", host: "muse", stdin: stdin,
                                   environment: ["MUSE_SESSION_ID": "root", "MUSE_THREAD_ID": "root"]) == nil)
        let child = try denyPayload(HookGuard.response(event: "PreToolUse", host: "muse", stdin: stdin,
                                                       environment: ["MUSE_SESSION_ID": "root", "MUSE_THREAD_ID": "child"]))
        #expect(child["permissionDecision"] as? String == "deny")
        // Missing identity is ambiguous, never silently root: deny with guidance.
        for environment in [["MUSE_SESSION_ID": "root"], ["MUSE_THREAD_ID": "root"], [:],
                            ["MUSE_SESSION_ID": "", "MUSE_THREAD_ID": ""]] {
            let output = try denyPayload(HookGuard.response(event: "PreToolUse", host: "muse",
                                                             stdin: stdin, environment: environment))
            #expect(output["permissionDecision"] as? String == "deny")
            let reason = try #require(output["permissionDecisionReason"] as? String)
            #expect(reason.contains("Muse"))
        }
    }

    @Test func unknownHostFailsOpen() {
        let stdin = Data(#"{"hook_event_name":"PreToolUse","agent_id":"agent-1"}"#.utf8)
        #expect(HookGuard.response(event: "PreToolUse", host: "codex", stdin: stdin,
                                   environment: [:]) == nil)
    }

    @Test func denyOutputIsOneParseableJSONObject() throws {
        let stdin = Data(#"{"hook_event_name":"PreToolUse","agent_id":"agent-1"}"#.utf8)
        let text = try #require(HookGuard.response(event: "PreToolUse", host: "claude", stdin: stdin))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
        #expect((try JSONSerialization.jsonObject(with: Data(trimmed.utf8))) is [String: Any])
    }
}

private actor CountingBridge: VoiceBridgeClientProtocol {
    var sent: [VoiceRequest] = []
    func send(_ request: VoiceRequest) async throws -> VoiceReply {
        sent.append(request)
        if request.operation == .attach {
            return VoiceReply(accepted: true, code: "attached",
                              attachment: VoiceAttachment(id: UUID(), epoch: 1))
        }
        return VoiceReply(accepted: true, code: "observed")
    }
}
