import AgentVoice
import AgentVoiceMCP
import Foundation
import MCP
import Testing

struct VoiceAdapterTests {
    @Test func invalidExplicitIdentityNeverFallsBackOrCreatesWork() async throws {
        let client = BridgeFixture(actions: [])
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "fixture")
        for invalid in [Value.string("not-a-uuid"), Value.int(7)] {
            do {
                _ = try await adapter.call(name: "on_stop", arguments: ["session_id": "session", "turn_id": "turn", "input_id": invalid])
                Issue.record("Invalid explicit input identity must fail before attaching.")
            } catch {}
        }
        #expect(await client.sent.isEmpty)
    }
    @Test func deadIdleSocketDoesNotDropTheFirstNewPrompt() async throws {
        let input = UUID()
        let client = BridgeFixture(actions: [
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 1))),
            .notSentFailure,
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 2))),
            .reply(.init(accepted: true, code: "input_opened", inputID: input))
        ])
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "fixture")
        let result = try await adapter.call(name: "on_user_prompt_submit", arguments: ["session_id": "session", "turn_id": "turn"])
        #expect(result.inputID == input)
        let sent = await client.sent
        #expect(sent.map(\.operation) == [.attach, .prompt, .attach, .prompt])
        #expect(sent[1].requestID == sent[3].requestID)
    }
    @Test func firstPromptAfterStaleConnectionIsReattachedAndDeliveredOnce() async throws {
        let input = UUID()
        let client = BridgeFixture(actions: [
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 1))),
            .reply(.init(accepted: false, code: "stale_attachment")),
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 2))),
            .reply(.init(accepted: true, code: "input_opened", inputID: input)),
            .reply(.init(accepted: true, code: "completion_unverified", state: .skippedMissingDraft))
        ])
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "fixture")
        let result = try await adapter.call(name: "on_user_prompt_submit", arguments: ["session_id": "session", "turn_id": "turn"])
        #expect(result.inputID == input)
        _ = try await adapter.call(name: "on_stop", arguments: ["session_id": "session", "turn_id": "turn"])
        let sent = await client.sent
        #expect(sent.map(\.operation) == [.attach, .prompt, .attach, .prompt, .stop])
        #expect(sent[1].requestID == sent[3].requestID)
        #expect(sent[3].attachment?.epoch == 2)
        #expect(sent[4].inputID == input)
    }

    @Test func cachedPromptRetryAfterUnknownOutcomeReturnsActionableErrorWithoutClobberingFreshWork() async throws {
        let firstID = UUID()
        let freshInput = UUID()
        let client = BridgeFixture(actions: [
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 1))),
            .unknownFailure,
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 2))),
            .reply(.init(accepted: true, code: "input_opened", inputID: freshInput)),
            .reply(.init(accepted: false, code: "stale_attachment")),
            .reply(.init(accepted: true, code: "completion_unverified", state: .awaitingCompletion))
        ])
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "fixture")
        let staleArgs: [String: Value] = ["session_id": "session", "turn_id": "old-turn",
                                          "request_id": .string(firstID.uuidString)]
        do {
            _ = try await adapter.call(name: "on_user_prompt_submit", arguments: staleArgs)
            Issue.record("Unknown-outcome prompt must throw.")
        } catch let error as VoiceBridgeTransportError {
            #expect(error.requestMayHaveBeenAccepted)
        }
        let fresh = try await adapter.call(name: "on_user_prompt_submit",
                                           arguments: ["session_id": "session", "turn_id": "new-turn"])
        #expect(fresh.inputID == freshInput)
        let retry = try await adapter.call(name: "on_user_prompt_submit", arguments: staleArgs)
        #expect(!retry.accepted)
        #expect(retry.code == "new_prompt_required")
        let sent = await client.sent
        #expect(sent.map(\.operation) == [.attach, .prompt, .attach, .prompt, .prompt])
        #expect(sent[1].requestID == firstID)
        #expect(sent[4].requestID == firstID)
        #expect(sent[1] == sent[4], "Identical retry must reuse the original envelope for receipt lookup.")
        // The fresh turn stays usable: the stale retry must not retire its mapping.
        _ = try await adapter.call(name: "on_stop", arguments: ["session_id": "session", "turn_id": "new-turn"])
        let afterStop = await client.sent
        #expect(afterStop.map(\.operation) == [.attach, .prompt, .attach, .prompt, .prompt, .stop])
        #expect(afterStop[5].inputID == freshInput)
    }

    @Test func cachedPromptCommittedReceiptStillReturnsOriginalReply() async throws {
        let firstID = UUID()
        let originalInput = UUID()
        let originalAttachment = VoiceAttachment(id: UUID(), epoch: 1)
        let client = BridgeFixture(actions: [
            .reply(.init(accepted: true, code: "attached", attachment: originalAttachment)),
            .unknownFailure,
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 2))),
            .reply(.init(accepted: true, code: "input_opened", inputID: UUID())),
            .reply(.init(accepted: true, code: "input_opened", inputID: originalInput))
        ])
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "fixture")
        let args: [String: Value] = ["session_id": "session", "turn_id": "old-turn",
                                     "request_id": .string(firstID.uuidString)]
        do { _ = try await adapter.call(name: "on_user_prompt_submit", arguments: args) } catch {}
        _ = try await adapter.call(name: "on_user_prompt_submit",
                                   arguments: ["session_id": "session", "turn_id": "new-turn"])
        let receipt = try await adapter.call(name: "on_user_prompt_submit", arguments: args)
        #expect(receipt.accepted)
        #expect(receipt.inputID == originalInput)
        let sent = await client.sent
        #expect(sent[1] == sent[4], "Committed receipt must use the original attachment, payload and timestamp.")
        #expect(sent[4].attachment == originalAttachment)
    }

    @Test func sessionOnlyStopIsForwardedForHostsWithoutTurnID() async throws {
        let client = BridgeFixture(actions: [
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 1))),
            .reply(.init(accepted: true, code: "auto_admitted", state: .queued))
        ])
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "claude")
        let result = try await adapter.call(name: "on_stop", arguments: ["session_id": "session"])
        #expect(result.code == "auto_admitted")
        let sent = await client.sent
        #expect(sent[1].operation == .stop)
        #expect(sent[1].inputID == nil && sent[1].nativeTurnID == nil)
    }

    @Test func freshAdapterForwardsNativeTurnForDurableResolution() async throws {
        let client = BridgeFixture(actions: [
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 1))),
            .reply(.init(accepted: true, code: "auto_admitted", state: .queued))
        ])
        // A fresh adapter has no in-memory turn mapping. It must still send
        // the call, carrying the native turn for store-side resolution,
        // instead of failing locally or substituting another turn.
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "fixture")
        let result = try await adapter.call(name: "on_stop", arguments: ["session_id": "session", "turn_id": "turn-7"])
        #expect(result.code == "auto_admitted")
        let sent = await client.sent
        #expect(sent.count == 2)
        #expect(sent[1].operation == .stop)
        #expect(sent[1].inputID == nil)
        #expect(sent[1].nativeTurnID == "turn-7")
    }

    @Test func transportFailureRetiresOwnershipButPreservesOriginalRetryEnvelope() async throws {
        let oldInput = UUID()
        let newInput = UUID()
        let client = BridgeFixture(actions: [
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 1))),
            .reply(.init(accepted: true, code: "input_opened", inputID: oldInput)),
            .failure,
            .reply(.init(accepted: true, code: "attached", attachment: .init(id: UUID(), epoch: 2))),
            .reply(.init(accepted: true, code: "input_opened", inputID: newInput)),
            .reply(.init(accepted: true, code: "prepared", inputID: oldInput))
        ])
        let adapter = VoiceAdapter(client: client, installationID: UUID(), host: "fixture")
        _ = try await adapter.call(name: "on_user_prompt_submit", arguments: ["session_id": "session", "turn_id": "old-turn"])
        let arguments: [String: Value] = ["session_id": "session", "input_id": .string(oldInput.uuidString), "request_id": .string(UUID().uuidString), "text": "The original response."]
        do { _ = try await adapter.call(name: "prepare_spoken_response", arguments: arguments); Issue.record("Expected transport failure") }
        catch {}
        let next = try await adapter.call(name: "on_user_prompt_submit", arguments: ["session_id": "session", "turn_id": "new-turn"])
        #expect(next.inputID == newInput)
        _ = try await adapter.call(name: "prepare_spoken_response", arguments: arguments)
        let sent = await client.sent
        #expect(sent[2] == sent[5], "Receipt retry must use the original attachment, payload and timestamp.")
        do { _ = try await adapter.call(name: "on_stop", arguments: ["session_id": "session", "turn_id": "old-turn"]); Issue.record("Old native mapping must be retired") }
        catch {}
    }
}

private actor BridgeFixture: VoiceBridgeClientProtocol {
    enum Action: Sendable { case reply(VoiceReply), failure, notSentFailure, unknownFailure }
    var sent: [VoiceRequest] = []
    private var actions: [Action]
    init(actions: [Action]) { self.actions = actions }
    func send(_ request: VoiceRequest) async throws -> VoiceReply {
        sent.append(request)
        guard !actions.isEmpty else { throw VoiceError.unavailable("Unexpected fixture request.") }
        switch actions.removeFirst() {
        case .reply(let reply): return reply
        case .failure: throw VoiceError.unavailable("Injected connection loss.")
        case .notSentFailure: throw VoiceBridgeTransportError(requestMayHaveBeenAccepted: false, message: "Injected dead idle socket.")
        case .unknownFailure: throw VoiceBridgeTransportError(requestMayHaveBeenAccepted: true, message: "Injected unknown-outcome timeout.")
        }
    }
}
