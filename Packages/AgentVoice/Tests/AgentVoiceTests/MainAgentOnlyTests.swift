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
            for tool in ["on_user_prompt_submit", "prepare_spoken_response", "on_stop",
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
        // Codex behavior stays unchanged: it never sends agent_id, and a
        // value there (or on unknown hosts) is not treated as child proof.
        for host in ["codex", "other", "fixture"] {
            let client = CountingBridge()
            let adapter = VoiceAdapter(client: client, installationID: UUID(), host: host)
            _ = try await adapter.call(name: "on_stop",
                                       arguments: ["session_id": "session",
                                                   "agent_id": "agent-child-1"])
            #expect(await client.sent.map(\.operation) == [.attach, .stop],
                    "Host \(host) must keep its existing behavior.")
        }
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
