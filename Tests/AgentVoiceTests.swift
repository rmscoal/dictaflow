import AgentVoice
import Foundation
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class AgentVoiceTests: XCTestCase {
    func testDisablingAgentVoiceDoesNotStopForegroundRecognition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtime = VoiceRuntimeFixture()
        let voice = AgentVoiceCoordinator(defaults: defaults, player: VoicePlayerFixture(), supportDirectory: root,
                                           runtime: runtime, appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let lease = voice.acquireForeground()
        voice.setEnabled(false)
        await voice.waitForShutdown()
        let stops = await runtime.stopCount
        XCTAssertEqual(stops, 0, "Disabling MCP output must not cancel the shared runtime's foreground ASR.")
        voice.releaseForeground(lease)
        voice.shutdown(); await voice.waitForShutdown()
    }
    func testForegroundLeaseAllowsQueueingButBlocksSynthesisAndSilencesPlaybackSynchronously() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtime = VoiceRuntimeFixture()
        let player = VoicePlayerFixture()
        let appID = "df-test-\(UUID().uuidString.prefix(8))"
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root, runtime: runtime, appIdentity: appID)
        defer {
            voice.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        voice.setEnabled(true)
        let recordingLease = voice.acquireForeground()
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: appID))
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "turn")
        let attachment = try await client.send(.init(session: session, operation: .attach)).attachment
        let input = try await client.send(.init(session: session, operation: .prompt, attachment: attachment)).inputID
        _ = try await client.send(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "The patch is ready, with one caveat."))
        let draft = try XCTUnwrap(voice.drafts.first)
        voice.speak(draft)
        try await waitUntil { voice.drafts.first?.state == .queued }
        let callsDuringRecording = await runtime.synthesisCount
        XCTAssertEqual(callsDuringRecording, 0)
        let transcriptionLease = voice.acquireForeground()
        voice.releaseForeground(recordingLease)
        await Task.yield()
        let callsDuringTranscription = await runtime.synthesisCount
        XCTAssertEqual(callsDuringTranscription, 0)
        voice.releaseForeground(transcriptionLease)
        try await waitUntil { player.playCount == 1 }
        let stops = player.stopCount
        let nextRecording = voice.acquireForeground()
        XCTAssertGreaterThan(player.stopCount, stops, "Starting dictation must silence locally before an await.")
        try await voice.waitForForegroundResources()
        XCTAssertFalse(voice.isSpeaking)
        XCTAssertEqual(voice.status, "Agent speech interrupted for dictation.")
        voice.releaseForeground(nextRecording)
        voice.shutdown()
        await voice.waitForShutdown()
    }

    func testExistingHistoryAndSettingsDecodeAsWhisper() throws {
        let encoder = JSONEncoder()
        var configurationJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(WhisperConfiguration.default)) as? [String: Any])
        configurationJSON.removeValue(forKey: "recognitionProvider")
        let configuration = try JSONDecoder().decode(WhisperConfiguration.self, from: JSONSerialization.data(withJSONObject: configurationJSON))
        XCTAssertEqual(configuration.recognitionProvider, .whisper)
        let original = WhisperTranscriptionResult(text: "Saved text", segments: [], detectedLanguageCode: "en", model: .base, taskMode: .transcribe, completedAt: Date())
        let decoded = try JSONDecoder().decode(WhisperTranscriptionResult.self, from: encoder.encode(original))
        XCTAssertEqual(decoded.speechModelName, "Whisper Base")
        let liquid = WhisperTranscriptionResult(text: "Liquid text", segments: [], detectedLanguageCode: nil, model: nil, taskMode: .transcribe, completedAt: Date(), recognitionProvider: .liquid)
        let roundTrip = try JSONDecoder().decode(WhisperTranscriptionResult.self, from: encoder.encode(liquid))
        XCTAssertNil(roundTrip.model)
        XCTAssertEqual(roundTrip.speechModelName, "Liquid LFM3-Audio-2B")
    }

    func testInterruptedSynthesisCannotPlayItsLateResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtime = SuspendedVoiceRuntimeFixture()
        let player = VoicePlayerFixture()
        let appID = "df-test-\(UUID().uuidString.prefix(8))"
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: runtime, appIdentity: appID)
        defer {
            voice.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: appID))
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "turn")
        let attachment = try await client.send(.init(session: session, operation: .attach)).attachment
        let input = try await client.send(.init(session: session, operation: .prompt, attachment: attachment)).inputID
        _ = try await client.send(.init(session: session, operation: .prepare, attachment: attachment,
                                       inputID: input, text: "This result must never be played after interruption."))
        voice.speak(try XCTUnwrap(voice.drafts.first))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await runtime.isSuspended), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await runtime.isSuspended
        XCTAssertTrue(started)
        let lease = voice.acquireForeground()
        await runtime.releaseLateResult()
        try await voice.waitForForegroundResources()
        XCTAssertEqual(player.playCount, 0)
        XCTAssertFalse(voice.isSpeaking)
        XCTAssertEqual(voice.drafts.first?.state, .cancelled)
        XCTAssertEqual(voice.status, "Agent speech interrupted for dictation.")
        voice.releaseForeground(lease)
        voice.shutdown(); await voice.waitForShutdown()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}

private actor VoiceRuntimeFixture: LiquidRuntimeProtocol {
    var synthesisCount = 0
    var stopCount = 0
    func synthesize(_ text: String) async throws -> LiquidSpeech {
        synthesisCount += 1
        return LiquidSpeech(wav: Data(), duration: 60)
    }
    func transcribe(wav: Data, english: Bool) async throws -> String { "Fixture transcription" }
    func stop() async { stopCount += 1 }
    func hasExited() async -> Bool { true }
}

/// Deliberately ignores cancellation until the test releases synthesis.
private actor SuspendedVoiceRuntimeFixture: LiquidRuntimeProtocol {
    private var result: CheckedContinuation<LiquidSpeech, Never>?
    var isSuspended: Bool { result != nil }
    func synthesize(_ text: String) async throws -> LiquidSpeech {
        await withCheckedContinuation { result = $0 }
    }
    func releaseLateResult() {
        result?.resume(returning: LiquidSpeech(wav: Data(), duration: 60))
        result = nil
    }
    func transcribe(wav: Data, english: Bool) async throws -> String { "Fixture transcription" }
    func stop() async {}
    func hasExited() async -> Bool { true }
}

@MainActor
private final class VoicePlayerFixture: AgentSpeechPlayerProtocol {
    var playCount = 0
    var stopCount = 0
    func play(_ wav: Data) throws -> TimeInterval { playCount += 1; return 60 }
    func stop() { stopCount += 1 }
}
