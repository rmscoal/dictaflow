import Combine
import Foundation
import GRDB
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class RecordingStartupTests: XCTestCase {
    func testWritingDraftsOnlyAffectInferenceAfterSaving() throws {
        let fixture = try RecordingStartupFixture()
        defer { fixture.cleanup() }
        let state = fixture.state
        state.updatePresetInstructions("Saved cleanup rule")
        XCTAssertFalse(state.savedEffectiveRefinementPrompt(taskMode: .transcribe).contains("Saved cleanup rule"))
        state.savePresetInstructions()
        XCTAssertTrue(state.savedEffectiveRefinementPrompt(taskMode: .transcribe).contains("Saved cleanup rule"))
        state.updateRefinementMode(.casualMessaging)
        XCTAssertEqual(state.currentPresetInstructions, "")
        state.updatePresetInstructions("Casual draft")
        state.updateRefinementMode(.smartCleanup)
        XCTAssertEqual(state.currentPresetInstructions, "Saved cleanup rule")
        state.updateRefinementMode(.diy)
        state.updateRefinementPromptText("# DIY draft")
        XCTAssertFalse(state.savedEffectiveRefinementPrompt(taskMode: .transcribe).contains("# DIY draft"))
        state.saveRefinementPromptText()
        XCTAssertTrue(state.savedEffectiveRefinementPrompt(taskMode: .translateToEnglish).contains("# DIY draft"))
        XCTAssertTrue(state.savedEffectiveRefinementPrompt(taskMode: .translateToEnglish).contains("Output English."))
        XCTAssertFalse(state.savedEffectiveRefinementPrompt(taskMode: .transcribe).contains("Saved cleanup rule"))
    }

    func testUnreadablePresetInstructionsAreKeptAndCanBeRecovered() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preset-instructions.json")
        let original = Data("{broken JSON with existing instructions".utf8)
        try original.write(to: file)
        let promptStore = FileRefinementPromptStore(directoryURL: directory)
        let fixture = try RecordingStartupFixture(promptStore: promptStore)
        defer { fixture.cleanup() }
        let state = fixture.state
        XCTAssertNotNil(state.refinementWritingError)
        state.updatePresetInstructions("New cleanup instructions")
        state.savePresetInstructions()
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(state.isPresetInstructionsDirty)
        XCTAssertNotNil(state.refinementWritingError)

        // Repair outside the app, then retry without restarting or losing drafts.
        try JSONEncoder().encode(["casualMessaging": "Keep emojis."]).write(to: file)
        state.savePresetInstructions()
        XCTAssertNil(state.refinementWritingError)
        XCTAssertFalse(state.isPresetInstructionsDirty)
        XCTAssertEqual(try promptStore.presetInstructions()["casualMessaging"], "Keep emojis.")
        state.updateRefinementMode(.casualMessaging)
        XCTAssertEqual(state.currentPresetInstructions, "Keep emojis.")
    }

    func testRetentionChangeOnlyRequiresConfirmationForAffectedRecordings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryRetention-\(UUID())")
        let store = SQLiteHistoryStore(root: root)
        let fixture = try RecordingStartupFixture(historyStore: store)
        defer { fixture.cleanup(); try? FileManager.default.removeItem(at: root) }
        var ids: [UUID] = []
        for _ in 0..<2 {
            let capture = try await store.prepareCapture(retention: .fourteenDays)
            try Data().write(to: capture.fileURL)
            try await store.markFinishing(capture.id)
            _ = try await store.finishCapture(capture.id, capture: DictationCapture(fileURL: capture.fileURL, duration: 1, capturedAt: Date()))
            await store.releaseAudio(capture.id)
            ids.append(capture.id)
        }
        await fixture.state.updateHistoryRetention(.off)
        let noDeletion = await fixture.state.updateHistoryRetention(.sevenDays)
        XCTAssertNil(noDeletion, "Off to seven days applies immediately when no recordings are affected")
        XCTAssertEqual(fixture.state.historyRetention, .sevenDays)

        await fixture.state.updateHistoryRetention(.fourteenDays)
        await fixture.state.updateHistoryRetention(.off)
        // Backdate only an isolated fixture recording to reproduce an older
        // recording retained under fourteen days while history is off.
        let database = try DatabaseQueue(path: root.appendingPathComponent("history.sqlite").path)
        let olderID = ids[0].uuidString
        try await database.write {
            try $0.execute(sql: "UPDATE recordings SET capturedAt = ?, expiresAt = ? WHERE id = ?", arguments: [Date().addingTimeInterval(-9 * 86400).timeIntervalSince1970, Date().addingTimeInterval(5 * 86400).timeIntervalSince1970, olderID])
        }
        let before = try await store.detail(ids[0])
        let needsConfirmation = await fixture.state.updateHistoryRetention(.sevenDays)
        XCTAssertEqual(needsConfirmation, 1)
        XCTAssertEqual(fixture.state.historyRetention, .off)
        let unchanged = try await store.detail(ids[0])
        XCTAssertEqual(unchanged.entry.expiresAt, before.entry.expiresAt, "Checking must not change expiry or delete history")
        XCTAssertFalse(fixture.state.isHistoryProcessing)

        await fixture.state.updateHistoryRetention(.sevenDays, confirmedDeletion: true)
        XCTAssertEqual(fixture.state.historyRetention, .sevenDays)
        let remaining = try await store.entries(search: "", limit: 50, offset: 0)
        XCTAssertEqual(remaining.map(\.id), [ids[1]], "Confirmation only deletes recordings beyond the new retention")
    }

    func testHistoryRetryFailurePreservesOriginalAndShowsError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryPipeline-\(UUID())")
        let store = SQLiteHistoryStore(root: root)
        let fixture = try RecordingStartupFixture(whisper: PipelineWhisperService(failsTranscription: true), usePipelineModels: true, historyStore: store)
        defer { fixture.cleanup(); try? FileManager.default.removeItem(at: root) }
        let capture = try await store.prepareCapture(retention: .sevenDays)
        try Data().write(to: capture.fileURL)
        try await store.markFinishing(capture.id)
        _ = try await store.finishCapture(capture.id, capture: DictationCapture(fileURL: capture.fileURL, duration: 1, capturedAt: Date()))
        let original = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(original, result: WhisperTranscriptionResult(text: "Preserved original", segments: [], detectedLanguageCode: "en", model: .small, taskMode: .transcribe, completedAt: Date()), error: nil)
        let newer = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(newer, result: WhisperTranscriptionResult(text: "Newer original", segments: [], detectedLanguageCode: "en", model: .small, taskMode: .transcribe, completedAt: Date()), error: nil)
        await store.releaseAudio(capture.id)
        await fixture.state.history.refresh()
        await fixture.state.history.select(capture.id)
        fixture.state.history.selectedTranscriptionID = original
        fixture.state.history.selectTranscription()
        fixture.state.showMainWindowPage(.history)
        let finished = expectation(description: "Failed retry finishes")
        var started = false
        let observation = fixture.state.$isHistoryProcessing.sink {
            if $0 { started = true }
            if started && !$0 { finished.fulfill() }
        }
        fixture.state.retryHistoryTranscription()
        XCTAssertEqual(fixture.state.processingHistoryID, capture.id)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertNil(fixture.state.processingHistoryID)
        observation.cancel()
        XCTAssertNotNil(fixture.state.history.errorMessage)
        XCTAssertTrue(fixture.state.history.errorMessage?.contains("The saved audio could not be read") == true)
        XCTAssertEqual(fixture.state.mainWindowPage, .history)
        XCTAssertEqual(fixture.state.history.displayedText, "Preserved original")
        let detail = try await store.detail(capture.id)
        XCTAssertEqual(detail.transcriptions.count, 3)
        XCTAssertEqual(detail.transcriptions.filter { $0.status == .failed }.count, 1)
        XCTAssertEqual(detail.transcriptions.first { $0.id == original }?.result?.text, "Preserved original")
    }

    func testSuccessfulRetryLabelsNewAttemptAndReportsTextChanges() async throws {
        for previousText in ["New result", "Old result"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryPipeline-\(UUID())")
            let store = SQLiteHistoryStore(root: root)
            let fixture = try RecordingStartupFixture(whisper: PipelineWhisperService(text: "New result"), usePipelineModels: true, refinementEnabled: false, historyStore: store)
            defer { fixture.cleanup(); try? FileManager.default.removeItem(at: root) }
            let capture = try await store.prepareCapture(retention: .sevenDays)
            try Data().write(to: capture.fileURL)
            try await store.markFinishing(capture.id)
            _ = try await store.finishCapture(capture.id, capture: DictationCapture(fileURL: capture.fileURL, duration: 1, capturedAt: Date()))
            let original = try await store.startTranscription(capture.id, configuration: .default)
            try await store.finishTranscription(original, result: WhisperTranscriptionResult(text: previousText, segments: [], detectedLanguageCode: "en", model: .small, taskMode: .transcribe, completedAt: Date()), error: nil)
            await store.releaseAudio(capture.id)
            await fixture.state.history.select(capture.id)
            let finished = expectation(description: "Retry completes for \(previousText)")
            var started = false
            let observation = fixture.state.$isHistoryProcessing.sink {
                if $0 { started = true }
                if started && !$0 { finished.fulfill() }
            }
            fixture.state.history.errorMessage = "Previous retry failed"
            fixture.state.retryHistoryTranscription()
            await fulfillment(of: [finished], timeout: 3)
            observation.cancel()
            XCTAssertNil(fixture.state.history.errorMessage, "A successful retry must not retain an old error banner")
            XCTAssertEqual(fixture.state.history.displayedText, "New result")
            let latest = try XCTUnwrap(fixture.state.history.transcription)
            XCTAssertEqual(fixture.state.history.transcriptionLabel(latest), "Attempt 2 · Latest")
            let first = try XCTUnwrap(fixture.state.history.detail?.transcriptions.first { $0.id == original })
            XCTAssertEqual(fixture.state.history.transcriptionLabel(first), "First attempt · Previous")
            XCTAssertEqual(fixture.state.history.retryMessages[capture.id], previousText == "New result" ? "Retry complete. Text unchanged." : "Retry complete. Text updated.")
            XCTAssertNil(fixture.state.lastTextInsertion)
        }
    }

    func testRefinementRetryKeepsSelectedOlderWhisperResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryPipeline-\(UUID())")
        let store = SQLiteHistoryStore(root: root)
        let refinement = PipelineRefinementService(expectedTranscript: "Older raw transcript")
        let fixture = try RecordingStartupFixture(refinement: refinement, usePipelineModels: true, refinementEnabled: false, historyStore: store)
        defer { fixture.cleanup(); try? FileManager.default.removeItem(at: root) }
        let capture = try await store.prepareCapture(retention: .sevenDays)
        try Data().write(to: capture.fileURL)
        try await store.markFinishing(capture.id)
        _ = try await store.finishCapture(capture.id, capture: DictationCapture(fileURL: capture.fileURL, duration: 1, capturedAt: Date()))
        let older = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(older, result: WhisperTranscriptionResult(text: "Older raw transcript", segments: [], detectedLanguageCode: "en", model: .small, taskMode: .transcribe, completedAt: Date()), error: nil)
        let newer = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(newer, result: WhisperTranscriptionResult(text: "Newer raw transcript", segments: [], detectedLanguageCode: "en", model: .small, taskMode: .transcribe, completedAt: Date()), error: nil)
        await store.releaseAudio(capture.id)
        await fixture.state.history.refresh()
        await fixture.state.history.select(capture.id)
        fixture.state.history.selectedTranscriptionID = older
        fixture.state.history.selectTranscription()
        let finished = expectation(description: "Refinement retry finishes")
        var started = false
        let observation = fixture.state.$isHistoryProcessing.sink {
            if $0 { started = true }
            if started && !$0 { finished.fulfill() }
        }
        fixture.state.retryHistoryRefinement()
        await fulfillment(of: [finished], timeout: 3)
        observation.cancel()
        XCTAssertEqual(fixture.state.history.selectedTranscriptionID, older)
        XCTAssertEqual(fixture.state.history.refinement?.transcriptionID, older)
        XCTAssertEqual(fixture.state.history.displayedText, "Older raw transcript refined")
        XCTAssertFalse(fixture.state.refinementConfiguration.isEnabled, "Manual refinement must leave the automatic refinement toggle off")
        let detail = try await store.detail(capture.id)
        XCTAssertEqual(detail.transcriptions.count, 2)
        XCTAssertEqual(detail.refinements.count, 1)
        let prompt = try XCTUnwrap(detail.refinements.first?.prompt)
        XCTAssertEqual(prompt, fixture.state.savedEffectiveRefinementPrompt(taskMode: .transcribe))
        XCTAssertFalse(prompt.contains("{{languageInstruction}}"))
    }

    func testFailedRefinementRetryPreservesSelectedOlderRefinement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryPipeline-\(UUID())")
        let store = SQLiteHistoryStore(root: root)
        let refinement = PipelineRefinementService(expectedTranscript: "Saved original", failsRefinement: true)
        let fixture = try RecordingStartupFixture(refinement: refinement, usePipelineModels: true, historyStore: store)
        defer { fixture.cleanup(); try? FileManager.default.removeItem(at: root) }
        let capture = try await store.prepareCapture(retention: .sevenDays)
        try Data().write(to: capture.fileURL)
        try await store.markFinishing(capture.id)
        _ = try await store.finishCapture(capture.id, capture: DictationCapture(fileURL: capture.fileURL, duration: 1, capturedAt: Date()))
        let transcription = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(transcription, result: WhisperTranscriptionResult(text: "Saved original", segments: [], detectedLanguageCode: "en", model: .small, taskMode: .transcribe, completedAt: Date()), error: nil)
        var refinementIDs: [UUID] = []
        for text in ["Older refinement", "Newer refinement"] {
            let attempt = try await store.startRefinement(transcription, configuration: .default, prompt: "prompt")
            try await store.finishRefinement(attempt, result: TranscriptRefinementResult(originalText: "Saved original", refinedText: text, model: .qwen3Small, mode: .smartCleanup, completedAt: Date()), error: nil)
            refinementIDs.append(attempt)
        }
        await store.releaseAudio(capture.id)
        await fixture.state.history.refresh()
        await fixture.state.history.select(capture.id)
        fixture.state.history.selectedRefinementID = refinementIDs[0]
        fixture.state.history.showsOriginal = false
        let finished = expectation(description: "Failed refinement retry finishes")
        var started = false
        let observation = fixture.state.$isHistoryProcessing.sink {
            if $0 { started = true }
            if started && !$0 { finished.fulfill() }
        }
        fixture.state.retryHistoryRefinement()
        await fulfillment(of: [finished], timeout: 3)
        observation.cancel()
        XCTAssertEqual(fixture.state.history.selectedRefinementID, refinementIDs[0])
        XCTAssertEqual(fixture.state.history.displayedText, "Older refinement")
        XCTAssertFalse(fixture.state.history.showsOriginal)
        XCTAssertTrue(fixture.state.history.errorMessage?.contains("Synthetic refinement failure") == true)
        let detail = try await store.detail(capture.id)
        XCTAssertEqual(detail.refinements.count, 3)
        XCTAssertEqual(detail.refinements.filter { $0.status == .failed }.count, 1)
    }

    func testEscapeDiscardsManagedHistoryAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryPipeline-\(UUID())")
        let store = SQLiteHistoryStore(root: root)
        let fixture = try RecordingStartupFixture(historyStore: store)
        defer { fixture.cleanup(); try? FileManager.default.removeItem(at: root) }
        fixture.volume.shouldWait = false
        let recording = expectation(description: "Managed recording starts")
        let observation = fixture.state.$recordingState.sink { if $0.isRecording { recording.fulfill() } }
        fixture.state.toggleDictation()
        await fulfillment(of: [recording], timeout: 2)
        observation.cancel()
        let url = fixture.recorder.fileURL
        XCTAssertTrue(url.path.hasPrefix(root.path))
        await fixture.state.cancelRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let entries = try await store.entries(search: "", limit: 50, offset: 0)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(fixture.state.lastTextInsertion)
    }

    func testFinishedManagedRecordingPersistsRawTextAndRetriesWithoutInsertion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryPipeline-\(UUID())")
        let store = SQLiteHistoryStore(root: root)
        let fixture = try RecordingStartupFixture(whisper: PipelineWhisperService(), refinement: PipelineRefinementService(), usePipelineModels: true, historyStore: store)
        defer { fixture.cleanup(); try? FileManager.default.removeItem(at: root) }
        fixture.volume.shouldWait = false
        let recording = expectation(description: "Managed recording starts")
        let observation = fixture.state.$recordingState.sink { if $0.isRecording { recording.fulfill() } }
        fixture.state.toggleDictation()
        await fulfillment(of: [recording], timeout: 2)
        observation.cancel()
        fixture.state.toggleDictation()
        // Coordinator includes insertion/cleanup after publishing transcription.
        for _ in 0..<100 where !fixture.state.canProcessHistory { try await Task.sleep(for: .milliseconds(10)) }
        let entries = try await store.entries(search: "", limit: 50, offset: 0)
        XCTAssertEqual(entries.count, 1)
        let id = try XCTUnwrap(entries.first?.id)
        let detail = try await store.detail(id)
        XCTAssertEqual(detail.transcriptions.count, 1)
        XCTAssertNotNil(detail.transcriptions.first?.result)
        await fixture.state.history.select(id)
        fixture.state.retryHistoryTranscription()
        for _ in 0..<100 where fixture.state.isHistoryProcessing { try await Task.sleep(for: .milliseconds(10)) }
        let retried = try await store.detail(id)
        XCTAssertEqual(retried.transcriptions.count, 2)
        XCTAssertNil(fixture.state.lastTextInsertion, "Synthetic empty transcript and retries must not insert")
    }

    func testEmptyTranscriptSkipsRefinementAndInsertion() async throws {
        let whisper = PipelineWhisperService()
        let refinement = PipelineRefinementService()
        let fixture = try RecordingStartupFixture(whisper: whisper, refinement: refinement, usePipelineModels: true)
        defer { fixture.cleanup() }
        fixture.volume.shouldWait = false

        let recording = expectation(description: "Recording starts")
        let recordingObservation = fixture.state.$recordingState.sink {
            if $0.isRecording { recording.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [recording], timeout: 2)
        recordingObservation.cancel()

        let completed = expectation(description: "No-speech result completes without insertion")
        let completedObservation = fixture.state.$statusMessage.sink {
            if $0 == "No speech was detected, so there was nothing to insert." { completed.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [completed], timeout: 2)
        completedObservation.cancel()
        let refinementCalls = await refinement.refineCalls
        XCTAssertEqual(refinementCalls, 0)
        XCTAssertEqual(fixture.state.lastTranscription?.refinementStatus, .skipped(reason: "No speech was detected."))
        XCTAssertNil(fixture.state.lastTextInsertion)
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertEqual(fixture.state.transcriptionState, .idle)
        // StartupInsertionService also fails on any insertion or clipboard write.
    }

    func testEncoderDownloadUsesDedicatedWarmupInsteadOfTranscription() async throws {
        let warmed = expectation(description: "Encoder warmup is called")
        let whisper = PipelineWhisperService(onWarmup: { warmed.fulfill() })
        let fixture = try RecordingStartupFixture(whisper: whisper, usePipelineModels: true)
        defer { fixture.cleanup() }
        fixture.state.downloadWhisperEncoder(fixture.state.whisperConfiguration.model)
        await fulfillment(of: [warmed], timeout: 2)
        let transcriptionCalls = await whisper.transcribeCalls
        XCTAssertEqual(transcriptionCalls, 0)
    }

    func testEmptyTranscriptPreservesOnboardingNoSpeechResult() async throws {
        let refinement = PipelineRefinementService()
        let fixture = try RecordingStartupFixture(whisper: PipelineWhisperService(), refinement: refinement, usePipelineModels: true)
        defer { fixture.cleanup() }
        fixture.volume.shouldWait = false
        fixture.permissions.accessibilityGranted = true
        fixture.state.handleApplicationLaunch()
        fixture.state.advanceOnboarding() // Welcome to permissions.
        fixture.state.advanceOnboarding() // Permissions to model preparation.
        fixture.state.advanceOnboarding() // Prepared model to shortcut practice.
        XCTAssertEqual(fixture.state.onboardingPresentation?.step, .shortcut)

        let recording = expectation(description: "Practice recording starts")
        let recordingObservation = fixture.state.$recordingState.sink {
            if $0.isRecording { recording.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [recording], timeout: 2)
        recordingObservation.cancel()
        let completed = expectation(description: "Practice returns no speech")
        let completedObservation = fixture.state.$onboardingPracticeResult.sink {
            if $0 == .noSpeech { completed.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [completed], timeout: 2)
        completedObservation.cancel()
        let refinementCalls = await refinement.refineCalls
        XCTAssertEqual(refinementCalls, 0)
        XCTAssertNil(fixture.state.lastTextInsertion)
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertEqual(fixture.state.transcriptionState, .idle)
    }

    func testRecordingStartsBeforeDuckingAndStopWaitsForVolumeRestoration() async throws {
        let fixture = try RecordingStartupFixture()
        defer { fixture.cleanup() }
        let ducking = expectation(description: "Ducking is waiting")
        fixture.volume.onBegin = { ducking.fulfill() }
        fixture.state.toggleDictation()
        await fulfillment(of: [ducking], timeout: 2)

        XCTAssertTrue(fixture.state.recordingState.isRecording)
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertEqual(fixture.recorder.startCalls, 1)
        XCTAssertFalse(fixture.state.isDictationActionDisabled)
        XCTAssertEqual(fixture.overlay.presentation?.phase, .recording)
        XCTAssertEqual(fixture.cues.played, [.startRecording])

        let stopped = expectation(description: "Capture stops while ducking is pending")
        fixture.recorder.onStop = { stopped.fulfill() }
        fixture.state.toggleDictation()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertEqual(fixture.volume.restoreCalls, 0)

        let restored = expectation(description: "Pending ducking finishes before restoration")
        fixture.volume.onRestore = { restored.fulfill() }
        fixture.volume.resume()
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertFalse(fixture.volume.isDucked)
        XCTAssertEqual(fixture.recorder.stopCalls, 1)
    }

    func testCancellationDuringPreparationHidesPillAndNeverStartsCapture() async throws {
        let fixture = try RecordingStartupFixture()
        defer { fixture.cleanup() }
        fixture.recorder.shouldWaitPreparation = true
        let preparing = expectation(description: "Audio preparation is waiting")
        fixture.recorder.onPrepare = { preparing.fulfill() }
        fixture.state.toggleDictation()
        await fulfillment(of: [preparing], timeout: 2)
        XCTAssertEqual(fixture.state.recordingState, .starting)
        XCTAssertTrue(fixture.overlay.presentation?.isCancellable == true)

        let stopping = expectation(description: "Cancellation reserves cleanup")
        let observation = fixture.state.$recordingState.sink {
            if $0 == .stopping { stopping.fulfill() }
        }
        let cancellation = Task { await fixture.state.cancelRecording() }
        await fulfillment(of: [stopping], timeout: 2)
        observation.cancel()
        XCTAssertNil(fixture.overlay.presentation)
        fixture.recorder.resumePreparation()
        await cancellation.value
        XCTAssertEqual(fixture.state.recordingState, .idle)
        XCTAssertEqual(fixture.recorder.startCalls, 0)
        XCTAssertEqual(fixture.volume.beginCalls, 0)
        XCTAssertTrue(fixture.cues.played.isEmpty)
        XCTAssertNil(fixture.state.recordingFailureMessage)
    }

    func testRepeatedToggleWhileRecorderStartsDoesNotResetTheSession() async throws {
        let fixture = try RecordingStartupFixture()
        defer { fixture.cleanup() }
        fixture.volume.shouldWait = false
        fixture.recorder.shouldWait = true
        let starting = expectation(description: "Recorder start is waiting")
        fixture.recorder.onStart = { starting.fulfill() }
        fixture.state.toggleDictation()
        await fulfillment(of: [starting], timeout: 2)
        fixture.state.toggleDictation()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.recorder.startCalls, 1)
        XCTAssertEqual(fixture.state.recordingState, .starting)

        let recording = expectation(description: "Recorder start finishes")
        let observation = fixture.state.$recordingState.sink {
            if $0.isRecording { recording.fulfill() }
        }
        fixture.recorder.resume()
        await fulfillment(of: [recording], timeout: 2)
        observation.cancel()
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertTrue(fixture.state.recordingState.isRecording)
        await fixture.state.cancelRecording()
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertEqual(fixture.state.recordingState, .idle)
    }

    func testPermissionDenialAndStartFailureAllowRetry() async throws {
        let fixture = try RecordingStartupFixture(permission: .denied)
        defer { fixture.cleanup() }
        let denied = expectation(description: "Permission denial returns to idle")
        var sawRequest = false
        let deniedObservation = fixture.state.$recordingState.sink {
            if $0 == .requestingPermission { sawRequest = true }
            if sawRequest && $0 == .idle { denied.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [denied], timeout: 2)
        deniedObservation.cancel()
        XCTAssertEqual(fixture.recorder.startCalls, 0)
        XCTAssertEqual(fixture.volume.beginCalls, 0)
        XCTAssertNil(fixture.overlay.presentation)

        fixture.permissions.permission = .granted
        fixture.volume.shouldWait = false
        fixture.recorder.failNextStart = true
        let failed = expectation(description: "Start failure returns to idle")
        var sawStarting = false
        let failedObservation = fixture.state.$recordingState.sink {
            if $0 == .starting { sawStarting = true }
            if sawStarting && $0 == .idle { failed.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [failed], timeout: 2)
        failedObservation.cancel()
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.state.isDictationActionDisabled)
        XCTAssertNil(fixture.overlay.presentation)

        let recording = expectation(description: "Retry starts recording")
        let recordingObservation = fixture.state.$recordingState.sink {
            if $0.isRecording { recording.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [recording], timeout: 2)
        recordingObservation.cancel()
        XCTAssertEqual(fixture.recorder.startCalls, 2)
        XCTAssertTrue(fixture.recorder.isRecording)
        await fixture.state.cancelRecording()
        XCTAssertEqual(fixture.state.recordingState, .idle)
    }
}

/// Uses the real coordinator with isolated settings and synthetic recording files.
@MainActor
private final class RecordingStartupFixture {
    let directory: URL
    let suiteName = "DictaFlowTests.\(UUID().uuidString)"
    let permissions: StartupPermissionService
    let volume = StartupVolumeService()
    let recorder: StartupRecorderService
    let overlay = StartupOverlayRouter()
    let cues = StartupCueService()
    let state: DictaFlowAppState

    init(
        permission: MicrophonePermissionState = .granted,
        whisper: WhisperServiceProtocol = WhisperCPPService(),
        refinement: TranscriptRefinementServiceProtocol = LlamaCLITranscriptRefinementService(),
        usePipelineModels: Bool = false,
        refinementEnabled: Bool? = nil,
        historyStore: HistoryStoreProtocol? = nil,
        promptStore: RefinementPromptStoreProtocol? = nil
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = UserDefaultsSettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        settings.saveAutomaticallyChecksForUpdates(false)
        settings.saveRecordingPlaybackBehavior(.lowerSystemVolume)
        var refinementConfiguration = RefinementConfiguration.default
        refinementConfiguration.isEnabled = refinementEnabled ?? usePipelineModels
        settings.saveRefinementConfiguration(refinementConfiguration)
        try Data("synthetic model".utf8).write(to: directory.appendingPathComponent(settings.whisperConfiguration.model.filename))
        permissions = StartupPermissionService(permission: permission)
        recorder = StartupRecorderService(fileURL: directory.appendingPathComponent("capture.m4a"))
        state = DictaFlowAppState(
            settingsStore: settings, permissionService: permissions,
            audioRecorderService: recorder, audioOutputVolumeService: volume,
            soundCueService: cues,
            hotkeyService: StartupHotkeyService(),
            modelDownloadService: usePipelineModels
                ? PipelineModelDownloadService(modelsDirectoryURL: directory)
                : WhisperModelDownloadService(modelsDirectoryURL: directory),
            whisperService: whisper,
            transcriptRefinementService: refinement,
            refinementPromptStore: promptStore ?? StartupPromptStore(directory: directory),
            textInsertionService: StartupInsertionService(),
            localNotificationService: StartupNotificationService(),
            appUpdateService: GitHubReleaseUpdateService(),
            historyStore: historyStore
        )
        state.attach(recordingOverlayRouter: overlay)
    }

    func cleanup() {
        state.prepareForTermination()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class StartupVolumeService: AudioOutputVolumeServiceProtocol {
    var shouldWait = true
    var beginCalls = 0
    var restoreCalls = 0
    var isDucked = false
    var onRestore: (() -> Void)?
    var onBegin: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    func beginDucking() async throws {
        beginCalls += 1
        if shouldWait {
            await withCheckedContinuation { continuation = $0; onBegin?() }
        }
        isDucked = true
    }
    func resume() { continuation?.resume(); continuation = nil }
    func restoreDucking() async throws {
        restoreCalls += 1
        isDucked = false
        onRestore?()
    }
    nonisolated func restoreDuckingForTermination() throws {}
}

@MainActor
private final class StartupRecorderService: AudioRecorderServiceProtocol {
    var fileURL: URL
    var isRecording = false
    var currentPowerLevel: Double { 0 }
    var startCalls = 0
    var stopCalls = 0
    var shouldWait = false
    var failNextStart = false
    var shouldWaitPreparation = false
    var onPrepare: (() -> Void)?
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    init(fileURL: URL) { self.fileURL = fileURL }
    func prepareRecording() async throws {
        if shouldWaitPreparation {
            await withCheckedContinuation { preparationContinuation = $0; onPrepare?() }
        }
    }
    func prepareRecording(at url: URL) async throws {
        fileURL = url
        try await prepareRecording()
    }
    func resumePreparation() { preparationContinuation?.resume(); preparationContinuation = nil }
    func shutdown() { isRecording = false }
    func startRecording() async throws -> URL {
        startCalls += 1
        guard !isRecording else { throw AudioRecorderServiceError.alreadyRecording }
        if shouldWait {
            await withCheckedContinuation { continuation = $0; onStart?() }
        }
        if failNextStart { failNextStart = false; throw AudioRecorderServiceError.failedToStart }
        try Data().write(to: fileURL)
        isRecording = true
        return fileURL
    }
    func resume() { continuation?.resume(); continuation = nil }
    func stopRecording() async throws -> DictationCapture {
        stopCalls += 1
        isRecording = false
        onStop?()
        return DictationCapture(fileURL: fileURL, duration: 0, capturedAt: Date())
    }
    func discardRecording() throws {
        isRecording = false
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AudioRecorderServiceError.notRecording
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

@MainActor
private final class StartupPermissionService: PermissionServiceProtocol {
    var permission: MicrophonePermissionState
    var accessibilityGranted = false
    init(permission: MicrophonePermissionState) { self.permission = permission }
    func currentMicrophonePermissionStatus() -> MicrophonePermissionState { permission }
    func requestMicrophonePermissionIfNeeded() async -> MicrophonePermissionState { permission }
    func isAccessibilityPermissionGranted() -> Bool { accessibilityGranted }
    func requestAccessibilityPermission() -> Bool { XCTFail("No insertion is expected"); return false }
    func openMicrophoneSettings() {}
    func openAccessibilitySettings() {}
}

@MainActor
private final class StartupHotkeyService: HotkeyServiceProtocol {
    func registerToggleHotkey(_ shortcut: GlobalShortcutDescriptor, handler: @escaping () -> Void) throws {}
    func unregisterToggleHotkey() {}
}

@MainActor
private final class StartupOverlayRouter: RecordingOverlayRouting {
    var presentation: RecordingOverlayPresentation?
    func updateOverlay(_ presentation: RecordingOverlayPresentation?, cancelAction: @escaping () -> Void) {
        self.presentation = presentation
    }
}

private final class StartupPromptStore: RefinementPromptStoreProtocol {
    let promptsDirectoryURL: URL
    init(directory: URL) { promptsDirectoryURL = directory }
    func promptTemplate() -> String { "" }
    func hasCustomPromptTemplate() -> Bool { false }
    func savePromptTemplate(_ template: String) throws {}
    func resetPromptTemplate() throws {}
    private var instructions: [String: String] = [:]
    func presetInstructions() throws -> [String: String] { instructions }
    func savePresetInstructions(_ instructions: [String: String]) throws { self.instructions = instructions }
}

@MainActor
private final class StartupInsertionService: TextInsertionServiceProtocol {
    func insertText(_ text: String, targetApplication: InsertionTargetApplication?, allowAccessibilityFeatures: Bool) async -> TextInsertionResult {
        XCTFail("No insertion is expected")
        return TextInsertionResult(text: text, method: .copyPanel, targetApplicationName: nil, completedAt: Date(), isInsertionConfirmed: false)
    }
    func copyTextToPasteboard(_ text: String) { XCTFail("No clipboard writes are expected") }
}

@MainActor
private final class StartupNotificationService: LocalNotificationServiceProtocol {
    func requestAuthorizationIfNeeded() {}
    func show(title: String, body: String) {}
}

private actor PipelineWhisperService: WhisperServiceProtocol {
    var transcribeCalls = 0
    let onWarmup: @Sendable () -> Void
    let failsTranscription: Bool
    let text: String
    init(onWarmup: @escaping @Sendable () -> Void = {}, failsTranscription: Bool = false, text: String = " \n") {
        self.onWarmup = onWarmup
        self.failsTranscription = failsTranscription
        self.text = text
    }
    func prepare(modelURL: URL) async throws {}
    func unloadModel() async {}
    func warmUpEncoder(audioFileURL: URL, modelURL: URL, configuration: WhisperConfiguration) async throws {
        onWarmup()
    }
    func transcribe(audioFileURL: URL, modelURL: URL, configuration: WhisperConfiguration) async throws -> WhisperTranscriptionResult {
        transcribeCalls += 1
        if failsTranscription { throw NSError(domain: "com.apple.coreaudio.avfaudio", code: 1954115647) }
        return WhisperTranscriptionResult(text: text, segments: [], detectedLanguageCode: nil,
            model: configuration.model, taskMode: configuration.taskMode, completedAt: Date())
    }
}

private actor PipelineRefinementService: TranscriptRefinementServiceProtocol {
    var refineCalls = 0
    let expectedTranscript: String?
    let failsRefinement: Bool
    init(expectedTranscript: String? = nil, failsRefinement: Bool = false) {
        self.expectedTranscript = expectedTranscript
        self.failsRefinement = failsRefinement
    }
    func isRuntimeAvailable(for model: RefinementModelDescriptor) async -> Bool { true }
    func prepare(modelURL: URL) async throws {}
    func reloadModels() async {}
    func stop() async {}
    func refine(transcript: String, whisperTaskMode: WhisperTaskMode, modelURL: URL,
                configuration: RefinementConfiguration, promptTemplate: String) async throws -> TranscriptRefinementResult {
        refineCalls += 1
        if let expectedTranscript { XCTAssertEqual(transcript, expectedTranscript) }
        else { XCTFail("An empty raw transcript must never reach refinement") }
        if failsRefinement { throw TranscriptRefinementServiceError.failedToRun("Synthetic refinement failure") }
        return TranscriptRefinementResult(originalText: transcript, refinedText: transcript + " refined",
            model: configuration.model, mode: configuration.mode, completedAt: Date())
    }
}

/// Synthetic prepared models let coordinator tests reach inference without weights or downloads.
@MainActor
private final class PipelineModelDownloadService: ModelDownloadServiceProtocol {
    let modelsDirectoryURL: URL
    init(modelsDirectoryURL: URL) { self.modelsDirectoryURL = modelsDirectoryURL }
    func installedModelFiles() -> [LocalModelFile] { [] }
    func deleteModelFiles(_ files: [LocalModelFile]) async throws -> Int64 { 0 }
    func cancelDownload(modelIdentifier: String) {}
    func removeIncompleteDownloads() -> Int64 { 0 }
    func isWhisperModelPrepared(_ model: WhisperModelDescriptor) -> Bool { true }
    func verifiedWhisperModelURL(for model: WhisperModelDescriptor) async -> URL? {
        modelsDirectoryURL.appendingPathComponent(model.filename)
    }
    func ensureModelAvailable(_ model: WhisperModelDescriptor, progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void) async throws -> URL {
        modelsDirectoryURL.appendingPathComponent(model.filename)
    }
    func isWhisperEncoderPrepared(_ model: WhisperModelDescriptor) -> Bool { true }
    func isWhisperEncoderDownloaded(_ model: WhisperModelDescriptor) -> Bool { false }
    func setWhisperEncoderEnabled(_ enabled: Bool, for model: WhisperModelDescriptor) async throws {}
    func removeOrphanedEncoders() -> Int64 { 0 }
    func ensureWhisperEncoderAvailable(_ model: WhisperModelDescriptor, progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void) async throws -> URL {
        modelsDirectoryURL.appendingPathComponent(model.encoderDirectoryName)
    }
    func deleteWhisperEncoder(_ model: WhisperModelDescriptor) async throws -> Int64 { 0 }
    func isRefinementModelPrepared(_ model: RefinementModelDescriptor) -> Bool { true }
    func verifiedRefinementModelURL(for model: RefinementModelDescriptor) async -> URL? {
        modelsDirectoryURL.appendingPathComponent(model.filename)
    }
    func ensureRefinementModelAvailable(_ model: RefinementModelDescriptor, progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void) async throws -> URL {
        modelsDirectoryURL.appendingPathComponent(model.filename)
    }
}

@MainActor
private final class StartupCueService: SoundCueServiceProtocol {
    var played: [SoundCue] = []
    func play(_ cue: SoundCue, style: SoundCueStyle) async throws { played.append(cue) }
    func stop() {}
}
