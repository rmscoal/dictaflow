import AgentVoice
import AgentVoiceMCP
import Foundation
import MCP
import Testing

struct MCPBridgeTests {
    @Test func lostCommittedReplyRetiresAttachmentAndIdenticalRetryReadsReceipt() async throws {
        let root = URL(fileURLWithPath: "/tmp/df-test-\(UUID().uuidString.prefix(8))")
        let socket = root.appendingPathComponent("voice.sock")
        let store = try VoiceStore(url: root.appendingPathComponent("voice.sqlite"))
        let fixture = LostReplyFixture()
        let server = LocalVoiceServer(socketURL: socket, handler: { request, connection in
            let reply = (try? await store.handle(request, connectionID: connection)) ?? VoiceReply(accepted: false, code: "test_storage_failure")
            if request.operation == .prepare {
                let shouldLoseReply = await fixture.record(request, reply: reply)
                if shouldLoseReply { try? await Task.sleep(for: .seconds(1)) }
            }
            return reply
        }, onDisconnect: { connection in
            try? await store.disconnect(connectionID: connection)
            await fixture.disconnected()
        })
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let adapter = VoiceAdapter(client: LocalVoiceClient(socketURL: socket), installationID: UUID(), host: "fixture")
        let first = try await adapter.call(name: "on_user_prompt_submit", arguments: ["session_id": "session", "turn_id": "old"])
        let oldInput = try #require(first.inputID)
        let arguments: [String: Value] = ["session_id": "session", "input_id": .string(oldInput.uuidString),
                                          "request_id": .string(UUID().uuidString), "text": "A committed response."]
        do {
            _ = try await adapter.call(name: "prepare_spoken_response", arguments: arguments)
            Issue.record("The committed reply must be lost")
        } catch let error as VoiceBridgeTransportError {
            #expect(error.requestMayHaveBeenAccepted)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await fixture.didDisconnect), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await fixture.didDisconnect)
        let fresh = try await adapter.call(name: "on_user_prompt_submit", arguments: ["session_id": "session", "turn_id": "fresh"])
        let freshInput = try #require(fresh.inputID)
        #expect(fresh.accepted && freshInput != oldInput)
        let receipt = try await adapter.call(name: "prepare_spoken_response", arguments: arguments)
        let captured = await fixture.captured
        try #require(captured.count == 2)
        #expect(captured[0].0 == captured[1].0)
        #expect(receipt == captured[0].1)
        let oldDrafts = try await store.drafts().filter { $0.inputID == oldInput }
        #expect(oldDrafts.count == 1)
        #expect(oldDrafts.first?.revision == 1)
        #expect(oldDrafts.first?.state == .interrupted)
        do {
            _ = try await adapter.call(name: "on_stop", arguments: ["session_id": "session", "turn_id": "old"])
            Issue.record("The old native mapping must be retired")
        } catch {}
        let prepared = try await adapter.call(name: "prepare_spoken_response", arguments: ["session_id": "session", "input_id": .string(freshInput.uuidString), "request_id": .string(UUID().uuidString), "text": "Fresh response."])
        #expect(prepared.accepted)
        let stop = try await adapter.call(name: "on_stop", arguments: ["session_id": "session", "turn_id": "fresh"])
        #expect(stop.state == .awaitingCompletion)
    }

    @Test func unknownPromptNeverAcceptedThenIdenticalRetryNeedsNewPrompt() async throws {
        let root = URL(fileURLWithPath: "/tmp/df-test-\(UUID().uuidString.prefix(8))")
        let socket = root.appendingPathComponent("voice.sock")
        let store = try VoiceStore(url: root.appendingPathComponent("voice.sqlite"))
        let fixture = DroppedPromptFixture()
        let server = LocalVoiceServer(socketURL: socket, handler: { request, connection in
            if request.operation == .prompt, await fixture.shouldDrop() {
                await fixture.record(request)
                try? await Task.sleep(for: .seconds(1))
                return VoiceReply(accepted: true, code: "input_opened", inputID: UUID())
            }
            if request.operation == .prompt { await fixture.record(request) }
            return (try? await store.handle(request, connectionID: connection)) ?? VoiceReply(accepted: false, code: "test_storage_failure")
        }, onDisconnect: { connection in
            try? await store.disconnect(connectionID: connection)
            await fixture.disconnected()
        })
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let adapter = VoiceAdapter(client: LocalVoiceClient(socketURL: socket), installationID: UUID(), host: "fixture")
        let firstID = UUID()
        let staleArgs: [String: Value] = ["session_id": "session", "turn_id": "old",
                                          "request_id": .string(firstID.uuidString)]
        do {
            _ = try await adapter.call(name: "on_user_prompt_submit", arguments: staleArgs)
            Issue.record("Dropped prompt must time out.")
        } catch let error as VoiceBridgeTransportError {
            #expect(error.requestMayHaveBeenAccepted)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await fixture.didDisconnect), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await fixture.didDisconnect)
        let fresh = try await adapter.call(name: "on_user_prompt_submit", arguments: ["session_id": "session", "turn_id": "fresh"])
        let freshInput = try #require(fresh.inputID)
        #expect(fresh.accepted)
        let retry = try await adapter.call(name: "on_user_prompt_submit", arguments: staleArgs)
        #expect(!retry.accepted)
        #expect(retry.code == "new_prompt_required")
        let captured = await fixture.captured
        try #require(captured.count == 3)
        #expect(captured[0] == captured[2], "Identical retry must reuse the original envelope.")
        #expect(captured[0].requestID == firstID)
        // No duplicate input: the fresh turn stays open and usable.
        let status = try await adapter.call(name: "get_speech_status", arguments: ["session_id": "session",
            "input_id": .string(freshInput.uuidString), "request_id": .string(UUID().uuidString)])
        #expect(status.state == .open)
        let stop = try await adapter.call(name: "on_stop", arguments: ["session_id": "session", "turn_id": "fresh"])
        #expect(stop.state == .awaitingCompletion || stop.state == .skippedMissingDraft)
    }

    @Test func realSocketRestartDeliversTheFirstPromptAndFencesTheOldInput() async throws {
        let root = URL(fileURLWithPath: "/tmp/df-test-\(UUID().uuidString.prefix(8))")
        let socket = root.appendingPathComponent("voice.sock")
        let store = try VoiceStore(url: root.appendingPathComponent("voice.sqlite"))
        let disconnected = DisconnectFixture()
        func makeServer() -> LocalVoiceServer {
            LocalVoiceServer(socketURL: socket, handler: { request, connection in
                (try? await store.handle(request, connectionID: connection)) ?? VoiceReply(accepted: false, code: "test_storage_failure")
            }, onDisconnect: { connection in
                try? await store.disconnect(connectionID: connection)
                await disconnected.mark()
            })
        }
        let firstServer = makeServer()
        try firstServer.start()
        let adapter = VoiceAdapter(client: LocalVoiceClient(socketURL: socket), installationID: UUID(), host: "fixture")
        let first = try await adapter.call(name: "on_user_prompt_submit", arguments: ["session_id": "session", "turn_id": "first"])
        firstServer.stop()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await disconnected.value), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await disconnected.value)
        let secondServer = makeServer()
        try secondServer.start()
        defer { secondServer.stop(); try? FileManager.default.removeItem(at: root) }
        let second = try await adapter.call(name: "on_user_prompt_submit", arguments: ["session_id": "session", "turn_id": "second"])
        #expect(second.accepted)
        #expect(second.inputID != first.inputID)
        let previous = try await adapter.call(name: "get_speech_status", arguments: ["session_id": "session", "input_id": .string(first.inputID!.uuidString), "request_id": .string(UUID().uuidString)])
        #expect(previous.state == .interrupted)
    }
    @Test func unavailableAppAndUnresponsiveBridgeHaveBoundedFailure() async throws {
        let root = URL(fileURLWithPath: "/tmp/df-test-\(UUID().uuidString.prefix(8))")
        let socket = root.appendingPathComponent("voice.sock")
        let client = LocalVoiceClient(socketURL: socket)
        let request = VoiceRequest(session: .init(installationID: UUID(), host: "fixture", sessionID: "session"), operation: .attach)
        let missingStart = ContinuousClock.now
        do { _ = try await client.send(request); Issue.record("Missing app must fail") } catch {}
        #expect(missingStart.duration(to: .now) < .seconds(1))
        let server = LocalVoiceServer(socketURL: socket, handler: { _, _ in
            try? await Task.sleep(for: .seconds(2))
            return VoiceReply(accepted: true, code: "late")
        }, onDisconnect: { _ in })
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let blockedStart = ContinuousClock.now
        do { _ = try await client.send(request); Issue.record("Unresponsive app must time out") } catch {}
        #expect(blockedStart.duration(to: .now) < .seconds(1.5))
    }

    @Test func realHelperRoundTripPreparesCleanRenditionButCannotAuthorizePlayback() async throws {
        let root = URL(fileURLWithPath: "/tmp/df-test-\(UUID().uuidString.prefix(8))")
        let socket = root.appendingPathComponent("voice.sock")
        let store = try VoiceStore(url: root.appendingPathComponent("voice.sqlite"))
        let server = LocalVoiceServer(socketURL: socket, handler: { request, connection in
            (try? await store.handle(request, connectionID: connection)) ?? VoiceReply(accepted: false, code: "test_storage_failure")
        }, onDisconnect: { connection in try? await store.disconnect(connectionID: connection) })
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let process = Process()
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = package.appendingPathComponent(".build/debug/dictaflow-mcp")
        process.arguments = ["--app-id", "com.dictaflow.dev", "--installation-id", UUID().uuidString, "--host", "fixture", "--socket-path", socket.path]
        let input = Pipe(); let output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let transport = StdioTransport(input: .init(rawValue: output.fileHandleForReading.fileDescriptor), output: .init(rawValue: input.fileHandleForWriting.fileDescriptor))
        let client = Client(name: "DictaFlow fixture", version: "1")
        _ = try await client.connect(transport: transport)
        let tools = try await client.listTools().tools
        #expect(tools.count == 5)
        let prompt = try await client.callTool(name: "on_user_prompt_submit", arguments: ["session_id": "session", "turn_id": "native-turn"])
        let block = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(prompt.content[0])) as? [String: Any])
        let text = try #require(block["text"] as? String)
        let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let hook = try #require(json["hookSpecificOutput"] as? [String: Any])
        let context = try #require(hook["additionalContext"] as? String)
        #expect(context.contains("Keep the written answer clean"))
        let inputString = try #require(context.components(separatedBy: "input_id: ").last?.prefix(36))
        let inputID = try #require(UUID(uuidString: String(inputString)))
        let requestID = UUID().uuidString
        let arguments: [String: Value] = ["session_id": "session", "input_id": .string(inputID.uuidString), "request_id": .string(requestID), "text": "The fix is ready. The integration test passes, and one manual check remains."]
        let preparation = try await client.callTool(name: "prepare_spoken_response", arguments: arguments)
        #expect(preparation.isError != true)
        let retry = try await client.callTool(name: "prepare_spoken_response", arguments: arguments)
        #expect(preparation.content == retry.content)
        _ = try await client.callTool(name: "on_stop", arguments: ["session_id": "session", "turn_id": "native-turn"])
        #expect(try await store.drafts().first?.state == .awaitingCompletion)
        let current = try #require(try await store.drafts().first)
        let revised = try await client.callTool(name: "prepare_spoken_response", arguments: [
            "session_id": "session", "input_id": .string(inputID.uuidString), "request_id": .string(UUID().uuidString),
            "text": "The tests pass, but deployment still needs a manual approval.",
            "replaces_draft_id": .string(current.id.uuidString), "expected_revision": .int(current.revision)
        ])
        #expect(revised.isError != true)
        #expect(try await store.drafts().first?.revision == 2)
        let rejectedStop = try await client.callTool(name: "on_stop", arguments: ["session_id": "session", "turn_id": "unknown", "input_id": .string(UUID().uuidString)])
        #expect(rejectedStop.isError == true)
        #expect(try await store.nextJob() == nil)
        await client.disconnect()
    }
}

private actor LostReplyFixture {
    var captured: [(VoiceRequest, VoiceReply)] = []
    var didDisconnect = false
    func record(_ request: VoiceRequest, reply: VoiceReply) -> Bool {
        captured.append((request, reply))
        return captured.count == 1
    }
    func disconnected() { didDisconnect = true }
}

private actor DisconnectFixture {
    var value = false
    func mark() { value = true }
}

private actor DroppedPromptFixture {
    var captured: [VoiceRequest] = []
    var didDisconnect = false
    private var dropped = false
    func shouldDrop() -> Bool {
        if dropped { return false }
        dropped = true
        return true
    }
    func record(_ request: VoiceRequest) { captured.append(request) }
    func disconnected() { didDisconnect = true }
}
