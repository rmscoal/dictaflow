import AgentVoice
import AVFoundation
import Foundation
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class AgentVoiceTests: XCTestCase {
    func testRetainedHistoryLoadsWithoutEnablingBridge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = try VoiceStore(url: root.appendingPathComponent("AgentVoice/voice.sqlite"))
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "previous")
        let connection = UUID()
        let attachment = try await store.handle(.init(session: session, operation: .attach), connectionID: connection).attachment
        let input = try await store.handle(.init(session: session, operation: .prompt, attachment: attachment), connectionID: connection).inputID
        _ = try await store.handle(.init(session: session, operation: .prepare, attachment: attachment,
                                         inputID: input, text: "Retained fixture rendition."), connectionID: connection)
        let voice = AgentVoiceCoordinator(defaults: defaults, player: VoicePlayerFixture(), supportDirectory: root,
                                          runtime: VoiceRuntimeFixture(), appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try await waitUntil { voice.drafts.count == 1 }
        XCTAssertFalse(voice.isEnabled)
        XCTAssertEqual(voice.drafts.first?.text, "Retained fixture rendition.")
        XCTAssertEqual(voice.drafts.first?.state, .interrupted)
        voice.shutdown(); await voice.waitForShutdown()
    }

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
        XCTAssertFalse(voice.isGenerating)
        let transcriptionLease = voice.acquireForeground()
        voice.releaseForeground(recordingLease)
        await Task.yield()
        let callsDuringTranscription = await runtime.synthesisCount
        XCTAssertEqual(callsDuringTranscription, 0)
        voice.releaseForeground(transcriptionLease)
        try await waitUntil { player.playCount == 1 }
        XCTAssertFalse(voice.isGenerating)
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
        XCTAssertTrue(voice.isGenerating)
        let lease = voice.acquireForeground()
        XCTAssertFalse(voice.isGenerating)
        await runtime.releaseLateResult()
        try await voice.waitForForegroundResources()
        XCTAssertEqual(player.playCount, 0)
        XCTAssertFalse(voice.isSpeaking)
        XCTAssertEqual(voice.drafts.first?.state, .cancelled)
        XCTAssertEqual(voice.status, "Agent speech interrupted for dictation.")
        voice.releaseForeground(lease)
        voice.shutdown(); await voice.waitForShutdown()
    }

    func testSynthesisFailureCanBeRetriedExplicitly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtime = FailingOnceVoiceRuntimeFixture()
        let player = VoicePlayerFixture()
        let appID = "df-test-\(UUID().uuidString.prefix(8))"
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root, runtime: runtime, appIdentity: appID)
        defer {
            voice.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: appID))
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "turn")
        let attachment = try await client.send(.init(session: session, operation: .attach)).attachment
        let input = try await client.send(.init(session: session, operation: .prompt, attachment: attachment)).inputID
        _ = try await client.send(.init(session: session, operation: .prepare, attachment: attachment, inputID: input, text: "Retry this response."))
        voice.speak(try XCTUnwrap(voice.drafts.first))
        try await waitUntil { voice.drafts.first?.state == .failed }
        let failed = try XCTUnwrap(voice.drafts.first)
        XCTAssertTrue(voice.status.contains("Agent speech failed"))
        XCTAssertEqual(player.playCount, 0)
        voice.speak(failed)
        try await waitUntil { player.playCount == 1 }
        XCTAssertEqual(voice.drafts.first?.id, failed.id)
        XCTAssertNotEqual(voice.drafts.first?.attemptID, failed.attemptID)
        XCTAssertEqual(voice.drafts.first?.text, failed.text)
        let calls = await runtime.synthesisCount
        XCTAssertEqual(calls, 2)
        voice.shutdown(); await voice.waitForShutdown()
    }

    func testForegroundInferenceWaitsForConfirmedExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtime = GatedVoiceRuntimeFixture()
        let voice = AgentVoiceCoordinator(defaults: defaults, player: VoicePlayerFixture(), supportDirectory: root,
                                          runtime: runtime, appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        defer {
            voice.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        await runtime.setExited(false)
        do {
            try await voice.waitForForegroundResources()
            XCTFail("Foreground inference must wait for the owned audio process to exit.")
        } catch { XCTAssertTrue(error is VoiceError) }
        await runtime.setExited(true)
        try await voice.waitForForegroundResources()
        voice.shutdown()
        await voice.waitForShutdown()
    }

    func testLiquidRecognizeHandlesMissingInvalidAndOverlimitWithoutDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtime = VoiceRuntimeFixture()
        let voice = AgentVoiceCoordinator(defaults: defaults, player: VoicePlayerFixture(), supportDirectory: root,
                                          runtime: runtime, appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        defer {
            voice.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = WhisperConfiguration.default
        do {
            _ = try await voice.recognize(root.appendingPathComponent("missing.m4a"), configuration: configuration)
            XCTFail("Missing audio must fail.")
        } catch {
            XCTAssertFalse(isInputTooLong(error), "Missing file must not report overlimit.")
        }
        let empty = root.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        do {
            _ = try await voice.recognize(empty, configuration: configuration)
            XCTFail("Empty audio must fail.")
        } catch {
            XCTAssertFalse(isInputTooLong(error), "Empty file must not report overlimit.")
        }
        let text = root.appendingPathComponent("note.txt")
        try Data("not-audio".utf8).write(to: text)
        do {
            _ = try await voice.recognize(text, configuration: configuration)
            XCTFail("Non-audio must fail.")
        } catch {
            XCTAssertFalse(isInputTooLong(error), "Non-audio must not report overlimit.")
        }
        let long = root.appendingPathComponent("long.wav")
        try writeSilence(to: long, seconds: 121)
        do {
            _ = try await voice.recognize(long, configuration: configuration)
            XCTFail("121 s Liquid input must fail.")
        } catch {
            XCTAssertTrue(isInputTooLong(error), "Overlimit must use inputTooLong for retention.")
            XCTAssertTrue(error.localizedDescription.contains("2 minutes"))
            XCTAssertTrue(error.localizedDescription.contains("recording is kept"))
        }
        let overlimitTranscriptions = await runtime.transcribeCount
        XCTAssertEqual(overlimitTranscriptions, 0, "Overlimit must not reach transcription.")
        let short = root.appendingPathComponent("short.wav")
        try writeSilence(to: short, seconds: 1)
        let result = try await voice.recognize(short, configuration: configuration)
        XCTAssertEqual(result.text, "Fixture transcription")
        XCTAssertEqual(result.recognitionProvider, .liquid)
        let validTranscriptions = await runtime.transcribeCount
        XCTAssertEqual(validTranscriptions, 1)
        voice.shutdown()
        await voice.waitForShutdown()
    }

    private func isInputTooLong(_ error: Error) -> Bool {
        if let voice = error as? VoiceError, case .inputTooLong = voice { return true }
        return false
    }

    private func writeSilence(to url: URL, seconds: Int) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(16_000)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            if let channel = buffer.floatChannelData?[0] {
                for i in 0..<Int(frames) { channel[i] = 0 }
            }
            for _ in 0..<seconds { try file.write(from: buffer) }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    /// Prepares one rendition through the local bridge and returns the draft the
    /// coordinator published for it. The bridge handler refreshes before
    /// replying, so the draft is visible when `send` returns.
    private func prepareDraft(voice: AgentVoiceCoordinator, client: LocalVoiceClient, sessionID: String) async throws -> VoiceDraft {
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: sessionID)
        let attachment = try await client.send(.init(session: session, operation: .attach)).attachment
        let input = try await client.send(.init(session: session, operation: .prompt, attachment: attachment)).inputID
        _ = try await client.send(.init(session: session, operation: .prepare, attachment: attachment,
                                       inputID: input, text: "Response for \(sessionID)."))
        return try XCTUnwrap(voice.drafts.first(where: { $0.session.sessionID == sessionID }))
    }

    /// A full speech queue rejects admission with an observable code instead of
    /// silently dropping the rendition. The coordinator's Play path can never
    /// outrun this cap: `prepare` counts every non-terminal draft against the
    /// same limit, so a 51st rendition is refused here before Play is offered.
    func testQueueFullPreparationRejectsWithObservableCode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var limits = VoiceLimits()
        limits.maxPending = 1
        let store = try VoiceStore(url: root.appendingPathComponent("voice.sqlite"), limits: limits)
        let connection = UUID()
        let firstSession = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "first")
        let firstAttachment = try await store.handle(.init(session: firstSession, operation: .attach), connectionID: connection).attachment
        let firstInput = try await store.handle(.init(session: firstSession, operation: .prompt, attachment: firstAttachment), connectionID: connection).inputID
        let first = try await store.handle(.init(session: firstSession, operation: .prepare, attachment: firstAttachment,
                                                inputID: firstInput, text: "First response."), connectionID: connection)
        XCTAssertTrue(first.accepted)
        let secondSession = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "second")
        let secondAttachment = try await store.handle(.init(session: secondSession, operation: .attach), connectionID: connection).attachment
        let secondInput = try await store.handle(.init(session: secondSession, operation: .prompt, attachment: secondAttachment), connectionID: connection).inputID
        let rejected = try await store.handle(.init(session: secondSession, operation: .prepare, attachment: secondAttachment,
                                                   inputID: secondInput, text: "Overflow response."), connectionID: connection)
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.code, "queue_full")
        XCTAssertEqual(rejected.message, "Finish the written answer normally. Do not retry with a new request ID.")
    }

    /// Playing an already-admitted row is rejected with an explicit error and
    /// the live attempt stays eligible.
    func testStalePlaySurfacesUnavailableAndKeepsLiveAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let voice = AgentVoiceCoordinator(defaults: defaults, player: VoicePlayerFixture(), supportDirectory: root,
                                          runtime: VoiceRuntimeFixture(), appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        defer {
            voice.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let draft = try await prepareDraft(voice: voice, client: client, sessionID: "stale-turn")
        voice.speak(draft)
        try await waitUntil { voice.drafts.first?.attemptID != nil }
        let admitted = try XCTUnwrap(voice.drafts.first)
        voice.speak(admitted)
        try await waitUntil { voice.activeError != nil }
        XCTAssertEqual(voice.activeError?.scope, .playback)
        XCTAssertEqual(voice.activeError?.message, "This response is no longer available.")
        XCTAssertEqual(voice.drafts.count, 1)
        XCTAssertEqual(voice.drafts.first?.id, admitted.id)
        voice.shutdown()
        await voice.waitForShutdown()
    }

    /// A retained terminal replay reaches the queue cap through Play, with a
    /// playback-scoped error and refreshed state, not a prepare-only code.
    func testRetainedTerminalReplayThroughPlayRespectsQueueCap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtime = VoiceRuntimeFixture()
        let player = VoicePlayerFixture()
        var limits = VoiceLimits()
        limits.maxPending = 1
        limits.maxPendingPerSession = 10
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: runtime, appIdentity: "df-test-\(UUID().uuidString.prefix(8))",
                                          limits: limits)
        defer {
            voice.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        voice.setEnabled(true)
        let lease = voice.acquireForeground()
        var terminalClient: LocalVoiceClient? = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let terminalSession = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "terminal-turn")
        let attachment = try await terminalClient!.send(.init(session: terminalSession, operation: .attach)).attachment
        let input = try await terminalClient!.send(.init(session: terminalSession, operation: .prompt, attachment: attachment)).inputID
        _ = try await terminalClient!.send(.init(session: terminalSession, operation: .prepare, attachment: attachment,
                                                inputID: input, text: "Retained terminal response."))
        terminalClient = nil
        try await waitUntil { voice.drafts.first(where: { $0.session.sessionID == "terminal-turn" })?.state == .interrupted }
        let interrupted = try XCTUnwrap(voice.drafts.first(where: { $0.session.sessionID == "terminal-turn" }))
        let fillerClient = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let filler = try await prepareDraft(voice: voice, client: fillerClient, sessionID: "filler-turn")
        voice.speak(filler)
        try await waitUntil { voice.drafts.first(where: { $0.session.sessionID == "filler-turn" })?.state == .queued }
        let queued = try XCTUnwrap(voice.drafts.first(where: { $0.session.sessionID == "filler-turn" }))
        XCTAssertEqual(interrupted.text, "Retained terminal response.")
        voice.speak(interrupted)
        try await waitUntil { voice.activeError != nil }
        XCTAssertEqual(voice.activeError?.scope, .playback)
        XCTAssertEqual(voice.activeError?.message, "The speech queue is full.")
        XCTAssertEqual(voice.drafts.count, 2)
        XCTAssertEqual(voice.drafts.first(where: { $0.id == queued.id })?.state, .queued)
        XCTAssertEqual(voice.drafts.first(where: { $0.id == interrupted.id })?.text, "Retained terminal response.")
        XCTAssertEqual(voice.drafts.first(where: { $0.id == interrupted.id })?.state, .interrupted)
        let syntheses = await runtime.synthesisCount
        XCTAssertEqual(syntheses, 0)
        XCTAssertEqual(player.playCount, 0)
        voice.releaseForeground(lease)
        voice.shutdown()
        await voice.waitForShutdown()
    }

    /// Queue expiry does not remove retained text or forbid an explicit replay.
    func testQueueExpiryKeepsHistoryManuallyPlayable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtime = VoiceRuntimeFixture()
        let player = VoicePlayerFixture()
        var limits = VoiceLimits()
        limits.preparedLifetime = 0.2
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: runtime, appIdentity: "df-test-\(UUID().uuidString.prefix(8))",
                                          limits: limits)
        defer {
            voice.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let draft = try await prepareDraft(voice: voice, client: client, sessionID: "expiring-turn")
        XCTAssertEqual(draft.state, .prepared)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(voice.drafts.first?.state, .prepared, "Displayed row stays stale until Play refreshes it.")
        voice.speak(draft)
        try await waitUntil { player.playCount == 1 }
        XCTAssertNil(voice.activeError)
        XCTAssertEqual(voice.drafts.first?.text, draft.text)
        let syntheses = await runtime.synthesisCount
        XCTAssertEqual(syntheses, 1)
        XCTAssertEqual(voice.history.first?.renditions.count, 1)
        voice.shutdown()
        await voice.waitForShutdown()
    }

    /// A successful retry after synthesis failure clears the stale error.
    func testSuccessfulRetryClearsStalePlaybackError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = VoicePlayerFixture()
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: FailingOnceVoiceRuntimeFixture(), appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        defer {
            voice.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let draft = try await prepareDraft(voice: voice, client: client, sessionID: "retry-turn")
        voice.speak(draft)
        try await waitUntil { voice.drafts.first?.state == .failed }
        try await waitUntil { voice.activeError != nil }
        XCTAssertEqual(voice.activeError?.scope, .playback)
        XCTAssertEqual(voice.activeError?.message, "Agent speech failed: Injected synthesis failure")
        let failed = try XCTUnwrap(voice.drafts.first)
        voice.speak(failed)
        try await waitUntil { player.playCount == 1 }
        try await waitUntil { voice.activeError == nil }
        XCTAssertEqual(voice.drafts.first?.id, failed.id)
        XCTAssertNotEqual(voice.drafts.first?.attemptID, failed.attemptID)
        XCTAssertEqual(voice.drafts.first?.text, failed.text)
        voice.shutdown()
        await voice.waitForShutdown()
    }
    func testAutomaticSpeechCorrectionAndPersistentUserStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = VoicePlayerFixture()
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: VoiceRuntimeFixture(), appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        defer { voice.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "automatic")
        let attachment = try await client.send(.init(session: session, operation: .attach)).attachment
        let input = try await client.send(.init(session: session, operation: .prompt, attachment: attachment,
                                               nativeTurnID: "turn-1")).inputID
        let first = try await client.send(.init(session: session, operation: .prepare, attachment: attachment,
                                               inputID: input, text: "First response."))
        XCTAssertEqual(player.playCount, 0)
        _ = try await client.send(.init(session: session, operation: .stop, attachment: attachment, inputID: input))
        try await waitUntil { voice.isSpeaking && player.playCount == 1 }
        _ = try await client.send(.init(session: session, operation: .stop, attachment: attachment, inputID: input))
        XCTAssertEqual(voice.history.first?.attempts.count, 1)
        XCTAssertTrue(voice.isSpeaking, "Duplicate Stop must not cancel a valid active attempt.")
        let second = try await client.send(.init(session: session, operation: .prepare, attachment: attachment,
                                                inputID: input, text: "Corrected response.", replacesDraftID: first.renditionID,
                                                expectedRevision: 1))
        try await waitUntil { !voice.isSpeaking && !voice.isGenerating }
        XCTAssertEqual(player.playCount, 1, "A correction needs its own Stop.")
        XCTAssertEqual(voice.history.first?.renditions.count, 2)
        _ = try await client.send(.init(session: session, operation: .stop, attachment: attachment, inputID: input))
        try await waitUntil { voice.isSpeaking && player.playCount == 2 }
        voice.stopSpeech()
        XCTAssertFalse(voice.isSpeaking)
        await voice.waitForShutdown()
        XCTAssertEqual(voice.history.first?.interaction.isSuppressed, true)
        _ = try await client.send(.init(session: session, operation: .prepare, attachment: attachment,
                                       inputID: input, text: "Late correction.", replacesDraftID: second.renditionID,
                                       expectedRevision: 2))
        let lateStop = try await client.send(.init(session: session, operation: .stop, attachment: attachment, inputID: input))
        XCTAssertEqual(lateStop.code, "stop_suppressed")
        XCTAssertEqual(player.playCount, 2)
        XCTAssertEqual(voice.history.first?.renditions.count, 3)
        XCTAssertEqual(voice.history.first?.attempts.count, 2)
        let nextInput = try await client.send(.init(session: session, operation: .prompt, attachment: attachment,
                                                   nativeTurnID: "turn-2")).inputID
        _ = try await client.send(.init(session: session, operation: .prepare, attachment: attachment,
                                       inputID: nextInput, text: "A new interaction."))
        _ = try await client.send(.init(session: session, operation: .stop, attachment: attachment, inputID: nextInput))
        try await waitUntil { player.playCount == 3 }
        voice.shutdown(); await voice.waitForShutdown()
    }

    func testStoppingOnePlaybackPreservesOtherQueuedResponses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = VoicePlayerFixture()
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: VoiceRuntimeFixture(), appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        defer { voice.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let first = try await prepareDraft(voice: voice, client: client, sessionID: "first")
        let second = try await prepareDraft(voice: voice, client: client, sessionID: "second")
        let third = try await prepareDraft(voice: voice, client: client, sessionID: "third")
        let firstID = try XCTUnwrap(first.renditionID)
        let secondID = try XCTUnwrap(second.renditionID)
        let thirdID = try XCTUnwrap(third.renditionID)
        await voice.playRendition(firstID)
        try await waitUntil { voice.isSpeaking && player.playCount == 1 }
        let firstAttempt = try XCTUnwrap(voice.history.flatMap(\.attempts).first { $0.renditionID == firstID })
        await voice.playRendition(secondID)
        await voice.playRendition(thirdID)
        XCTAssertEqual(voice.history.flatMap(\.attempts).filter { $0.state == .queued }.count, 2)

        await voice.stopPlayback(attemptID: firstAttempt.id)
        try await waitUntil {
            voice.isSpeaking && voice.history.flatMap(\.attempts).contains { $0.renditionID == secondID && $0.state == .playing }
        }
        XCTAssertEqual(player.playCount, 2)
        XCTAssertEqual(voice.history.flatMap(\.attempts).first { $0.id == firstAttempt.id }?.state, .cancelled)
        XCTAssertEqual(voice.history.first { $0.id == first.inputID }?.interaction.isSuppressed, true)
        XCTAssertEqual(voice.history.first { $0.id == second.inputID }?.interaction.isSuppressed, false)
        XCTAssertEqual(voice.history.flatMap(\.attempts).first { $0.renditionID == thirdID }?.state, .queued)

        // A delayed click from the stopped bubble cannot stop the next response.
        let stops = player.stopCount
        await voice.stopPlayback(attemptID: firstAttempt.id)
        XCTAssertEqual(player.stopCount, stops)
        XCTAssertTrue(voice.isSpeaking)
        XCTAssertEqual(voice.history.flatMap(\.attempts).first { $0.renditionID == secondID }?.state, .playing)

        // The toolbar and floating control retain their global Stop behavior.
        voice.stopSpeech()
        await voice.waitForShutdown()
        XCTAssertFalse(voice.isSpeaking)
        for draft in [second, third] {
            let record = try XCTUnwrap(voice.history.first { $0.id == draft.inputID })
            XCTAssertTrue(record.interaction.isSuppressed)
            XCTAssertEqual(record.attempts.last?.state, .cancelled)
        }
        voice.shutdown(); await voice.waitForShutdown()
    }

    func testStoppingExpiredSynthesisRejectsLateResultAndContinuesQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtime = SuspendedVoiceRuntimeFixture()
        let player = VoicePlayerFixture()
        var limits = VoiceLimits()
        limits.queueLifetime = 1
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: runtime, appIdentity: "df-test-\(UUID().uuidString.prefix(8))", limits: limits)
        defer { voice.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let first = try await prepareDraft(voice: voice, client: client, sessionID: "slow")
        let second = try await prepareDraft(voice: voice, client: client, sessionID: "next")
        await voice.playRendition(try XCTUnwrap(first.renditionID))
        try await waitUntil { voice.isGenerating && voice.history.flatMap(\.attempts).contains { $0.state == .synthesizing } }
        let attempt = try XCTUnwrap(voice.history.flatMap(\.attempts).first { $0.state == .synthesizing })
        try await Task.sleep(for: .milliseconds(1_100))
        await voice.playRendition(try XCTUnwrap(second.renditionID))
        XCTAssertEqual(voice.history.flatMap(\.attempts).first { $0.id == attempt.id }?.state, .expired)

        await voice.stopPlayback(attemptID: attempt.id)
        XCTAssertFalse(voice.isGenerating, "Stop must release an in-flight runtime even after its attempt expires.")
        await runtime.releaseLateResult()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await runtime.isSuspended), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let nextStarted = await runtime.isSuspended
        XCTAssertTrue(nextStarted)
        XCTAssertEqual(player.playCount, 0, "The cancelled synthesis result must never reach playback.")
        await runtime.releaseLateResult()
        try await waitUntil { voice.isSpeaking && player.playCount == 1 }
        XCTAssertEqual(voice.history.first { $0.id == second.inputID }?.attempts.last?.state, .playing)
        XCTAssertEqual(voice.history.first { $0.id == second.inputID }?.interaction.isSuppressed, false)
        voice.shutdown(); await voice.waitForShutdown()
    }

    func testManualModeRetainsResponseAndDeletionStopsPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = VoicePlayerFixture()
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: VoiceRuntimeFixture(), appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        defer { voice.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        voice.setAdmissionPolicy(.manualOnly)
        try await waitUntil { voice.admissionPolicy == .manualOnly }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "quiet")
        let attachment = try await client.send(.init(session: session, operation: .attach)).attachment
        let input = try await client.send(.init(session: session, operation: .prompt, attachment: attachment)).inputID
        let response = try await client.send(.init(session: session, operation: .prepare, attachment: attachment,
                                                  inputID: input, text: "Read when ready."))
        _ = try await client.send(.init(session: session, operation: .stop, attachment: attachment, inputID: input))
        XCTAssertEqual(player.playCount, 0)
        XCTAssertEqual(voice.history.first?.renditions.count, 1)
        await voice.playRendition(try XCTUnwrap(response.renditionID))
        try await waitUntil { voice.isSpeaking }
        voice.deleteInteraction(try XCTUnwrap(input))
        XCTAssertFalse(voice.isSpeaking)
        try await waitUntil { voice.history.isEmpty }
        _ = try await client.send(.init(session: session, operation: .stop, attachment: attachment, inputID: input))
        XCTAssertEqual(player.playCount, 1)
        XCTAssertTrue(voice.history.isEmpty)
        voice.shutdown(); await voice.waitForShutdown()
    }

    func testAdmissionWhileWorkerIsRetiringStartsPlaybackWithoutAnotherRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = VoicePlayerFixture()
        let gate = IdleRefreshGate()
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: VoiceRuntimeFixture(), appIdentity: "df-test-\(UUID().uuidString.prefix(8))",
                                          beforeIdleRefresh: { await gate.pauseOnce() })
        defer {
            gate.resume()
            voice.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "worker-wakeup")
        let attachment = try await client.send(.init(session: session, operation: .attach)).attachment
        try await waitUntil { gate.isPaused }
        let input = try await client.send(.init(session: session, operation: .prompt, attachment: attachment)).inputID
        let response = try await client.send(.init(session: session, operation: .prepare, attachment: attachment,
                                                    inputID: input, text: "Speak this without another request."))
        await voice.playRendition(try XCTUnwrap(response.renditionID))
        XCTAssertEqual(voice.history.first?.attempts.first?.state, .queued)
        XCTAssertEqual(player.playCount, 0)
        gate.resume()
        try await waitUntil { player.playCount == 1 }
        voice.shutdown(); await voice.waitForShutdown()
    }

    func testOverlayShowsDuringAutomaticSpeechAndHidesOnInterruption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = VoicePlayerFixture()
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: VoiceRuntimeFixture(), appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        let overlay = AgentVoiceOverlayCoordinator(voice: voice) {}
        defer { voice.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        voice.setEnabled(true)
        XCTAssertFalse(overlay.isControlVisible)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "overlay-auto")
        let attachment = try await client.send(.init(session: session, operation: .attach)).attachment
        let input = try await client.send(.init(session: session, operation: .prompt, attachment: attachment)).inputID
        _ = try await client.send(.init(session: session, operation: .prepare, attachment: attachment,
                                        inputID: input, text: "Overlay speaks this."))
        _ = try await client.send(.init(session: session, operation: .stop, attachment: attachment, inputID: input))
        try await waitUntil { voice.isGenerating || voice.isSpeaking }
        XCTAssertTrue(overlay.isControlVisible, "The control must appear while speech generates.")
        try await waitUntil { voice.isSpeaking }
        XCTAssertTrue(overlay.isControlVisible, "The control must stay visible while speaking.")
        voice.stopSpeech()
        try await waitUntil { !voice.isSpeaking && !voice.isGenerating }
        try await waitUntil { !overlay.isControlVisible }
        voice.shutdown(); await voice.waitForShutdown()
    }

    func testOverlayOffersManualReadyControlAfterStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DictaFlow.AgentVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = VoicePlayerFixture()
        let voice = AgentVoiceCoordinator(defaults: defaults, player: player, supportDirectory: root,
                                          runtime: VoiceRuntimeFixture(), appIdentity: "df-test-\(UUID().uuidString.prefix(8))")
        let overlay = AgentVoiceOverlayCoordinator(voice: voice) {}
        defer { voice.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        voice.setAdmissionPolicy(.manualOnly)
        try await waitUntil { voice.admissionPolicy == .manualOnly }
        voice.setEnabled(true)
        let client = LocalVoiceClient(socketURL: VoicePaths.socketURL(appID: voice.appID))
        let session = VoiceSession(installationID: UUID(), host: "fixture", sessionID: "overlay-manual")
        let attachment = try await client.send(.init(session: session, operation: .attach)).attachment
        let input = try await client.send(.init(session: session, operation: .prompt, attachment: attachment)).inputID
        let response = try await client.send(.init(session: session, operation: .prepare, attachment: attachment,
                                                  inputID: input, text: "Read when ready."))
        let stop = try await client.send(.init(session: session, operation: .stop, attachment: attachment, inputID: input))
        XCTAssertEqual(stop.code, "stop_observed_manual_only")
        XCTAssertEqual(player.playCount, 0)
        // The Stop must endorse the revision so the overlay can offer replay.
        try await waitUntil { voice.history.first?.interaction.stopEligibleRevision != nil }
        XCTAssertTrue(overlay.isControlVisible, "Manual mode must surface the Response ready control.")
        await voice.playRendition(try XCTUnwrap(response.renditionID))
        try await waitUntil { voice.isSpeaking }
        XCTAssertTrue(overlay.isControlVisible)
        voice.stopSpeech()
        try await waitUntil { !voice.isSpeaking && !voice.isGenerating }
        try await waitUntil { !overlay.isControlVisible }
        voice.shutdown(); await voice.waitForShutdown()
    }

}

@MainActor
private final class IdleRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didPause = false
    var isPaused: Bool { continuation != nil }

    func pauseOnce() async {
        guard !didPause else { return }
        didPause = true
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        didPause = true
        continuation?.resume()
        continuation = nil
    }
}

private actor FailingOnceVoiceRuntimeFixture: LiquidRuntimeProtocol {
    var synthesisCount = 0
    func synthesize(_ text: String) async throws -> LiquidSpeech {
        synthesisCount += 1
        if synthesisCount == 1 { throw VoiceError.unavailable("Injected synthesis failure") }
        return LiquidSpeech(wav: Data(), duration: 60)
    }
    func transcribe(wav: Data, translateToEnglish: Bool) async throws -> String { "Fixture transcription" }
    func stop() async {}
    func hasExited() async -> Bool { true }
}

private actor VoiceRuntimeFixture: LiquidRuntimeProtocol {
    var synthesisCount = 0
    var stopCount = 0
    var transcribeCount = 0
    func synthesize(_ text: String) async throws -> LiquidSpeech {
        synthesisCount += 1
        return LiquidSpeech(wav: Data(), duration: 60)
    }
    func transcribe(wav: Data, translateToEnglish: Bool) async throws -> String {
        transcribeCount += 1
        return "Fixture transcription"
    }
    func stop() async { stopCount += 1 }
    func hasExited() async -> Bool { true }
}

/// Deliberately ignores cancellation until the test releases synthesis.
private actor GatedVoiceRuntimeFixture: LiquidRuntimeProtocol {
    private var exited = true
    func setExited(_ value: Bool) { exited = value }
    func synthesize(_ text: String) async throws -> LiquidSpeech { LiquidSpeech(wav: Data(), duration: 60) }
    func transcribe(wav: Data, translateToEnglish: Bool) async throws -> String { "Fixture transcription" }
    func stop() async {}
    func hasExited() async -> Bool { exited }
}

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
    func transcribe(wav: Data, translateToEnglish: Bool) async throws -> String { "Fixture transcription" }
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
