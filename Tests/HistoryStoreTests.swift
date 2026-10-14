import AVFoundation
import GRDB
import XCTest
@testable import DictaFlow_Dev

final class HistoryStoreTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteHistoryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DictaFlowHistoryTests-\(UUID())")
        store = SQLiteHistoryStore(root: root)
    }

    override func tearDownWithError() throws {
        store = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func writeAudio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private func recording() async throws -> HistoryCapture {
        let capture = try await store.prepareCapture(retention: .sevenDays)
        try writeAudio(capture.fileURL)
        try await store.markFinishing(capture.id)
        _ = try await store.finishCapture(capture.id, capture: DictationCapture(fileURL: capture.fileURL, duration: 1, capturedAt: Date()))
        return capture
    }

    private func result(_ text: String) -> WhisperTranscriptionResult {
        WhisperTranscriptionResult(text: text, segments: [], detectedLanguageCode: "en", model: .base, taskMode: .transcribe, completedAt: Date())
    }

    @MainActor
    func testToneOnlyHistoryAndRefinementKeepRawAndFinalOutputs() async throws {
        let capture = try await recording()
        let attempt = try await store.startTranscription(capture.id, configuration: .default)
        var raw = result("I'm late.")
        raw.toneFormatting = TextToneFormatter.format(raw.text, tone: .formal, isEnglish: true)
        try await store.finishTranscription(attempt, result: raw, error: nil)
        await store.releaseAudio(capture.id)
        let model = HistoryViewModel(store: store)
        await model.select(capture.id)
        XCTAssertEqual(model.displayedText, "I am late.")
        model.textView = .original
        XCTAssertEqual(model.displayedText, "I'm late.")
        let matches = try await store.entries(search: "am late", limit: 50, offset: 0)
        XCTAssertEqual(matches.first?.preview, "I am late.")
        XCTAssertEqual(matches.count, 1)
        let crossOutputMatches = try await store.entries(search: "I'm late. I am late.", limit: 50, offset: 0)
        XCTAssertTrue(crossOutputMatches.isEmpty, "Search must not join raw and final text into an invented sentence")

        let refinement = try await store.startRefinement(attempt, configuration: .default, prompt: "prompt")
        var refined = TranscriptRefinementResult(originalText: raw.text, refinedText: "I can't go.", model: .qwen3Small, mode: .smartCleanup, completedAt: Date())
        refined.toneFormatting = TextToneFormatter.format(refined.refinedText, tone: .formal, isEnglish: true)
        try await store.finishRefinement(refinement, result: refined, error: nil)
        await model.select(capture.id)
        XCTAssertEqual(model.displayedText, "I cannot go.")
        model.textView = .refined
        XCTAssertEqual(model.displayedText, "I can't go.")
        model.textView = .original
        XCTAssertEqual(model.displayedText, "I'm late.")
        let saved = try await store.detail(capture.id)
        XCTAssertEqual(saved.refinements.first?.result?.toneFormatting?.formatterVersion, 1)
        let finalMatches = try await store.entries(search: "cannot", limit: 50, offset: 0)
        XCTAssertEqual(finalMatches.first?.preview, "I cannot go.")
        let rawMatches = try await store.entries(search: "can't", limit: 50, offset: 0)
        XCTAssertEqual(rawMatches.count, 1)
    }

    func testVersionTwoDatabaseMigratesWithoutChangingLegacyText() async throws {
        let capture = try await recording()
        let attempt = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(attempt, result: result("Legacy original."), error: nil)
        await store.releaseAudio(capture.id)
        store = nil
        // Reconstruct the prior schema in this isolated fixture. Its blobs have no tone field.
        let db = try DatabaseQueue(path: root.appendingPathComponent("history.sqlite").path)
        try await db.write {
            try $0.execute(sql: "ALTER TABLE transcription_results DROP COLUMN finalText")
            try $0.execute(sql: "ALTER TABLE refinement_results DROP COLUMN finalText")
            try $0.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'history-v3-tone-output'")
        }
        store = SQLiteHistoryStore(root: root)
        try await store.initialize()
        let saved = try await store.detail(capture.id)
        XCTAssertEqual(saved.transcriptions.first?.result?.insertionText, "Legacy original.")
        XCTAssertNil(saved.transcriptions.first?.result?.toneFormatting)
        XCTAssertEqual(saved.entry.preview, "Legacy original.")
        let newAttempt = try await store.startTranscription(capture.id, configuration: .default)
        var newResult = result("I'm here.")
        newResult.toneFormatting = TextToneFormatter.format(newResult.text, tone: .formal, isEnglish: true)
        try await store.finishTranscription(newAttempt, result: newResult, error: nil)
        let updated = try await store.detail(capture.id)
        XCTAssertEqual(updated.entry.preview, "I am here.")
        XCTAssertEqual(updated.transcriptions.count, 2)
    }

    @MainActor
    func testCardSelectionAndRefreshPreserveChosenPreviousResult() async throws {
        let capture = try await recording()
        let older = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(older, result: result("older original"), error: nil)
        let refinement = try await store.startRefinement(older, configuration: .default, prompt: "prompt")
        try await store.finishRefinement(refinement, result: TranscriptRefinementResult(originalText: "older original", refinedText: "Older refined.", model: .qwen3Small, mode: .smartCleanup, completedAt: Date()), error: nil)
        let newer = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(newer, result: result("newer original"), error: nil)
        await store.releaseAudio(capture.id)
        let other = try await recording()
        await store.releaseAudio(other.id)
        let model = HistoryViewModel(store: store)

        await model.refresh()
        XCTAssertNil(model.selectedID, "The feed starts with collapsed cards")
        await model.toggleSelection(capture.id)
        XCTAssertEqual(model.displayedText, "newer original")
        model.selectedTranscriptionID = older
        model.selectTranscription()
        XCTAssertEqual(model.displayedText, "Older refined.")
        XCTAssertEqual(model.refinement?.transcriptionID, older)
        await model.refresh()
        XCTAssertEqual(model.selectedTranscriptionID, older)
        XCTAssertEqual(model.displayedText, "Older refined.")

        await model.toggleSelection(other.id)
        XCTAssertEqual(model.selectedID, other.id, "Selecting another card replaces the expanded detail")
        XCTAssertEqual(model.detail?.entry.id, other.id)
        await model.toggleSelection(other.id)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.detail)
        XCTAssertNil(model.selectedTranscriptionID)
        XCTAssertNil(model.selectedRefinementID)
        await model.refresh()
        XCTAssertNil(model.selectedID, "Refreshing must not reopen a collapsed card")
    }

    @MainActor
    func testRefreshPreservesLoadedPagesAndSelectedOlderCard() async throws {
        let oldest = try await recording()
        let original = try await store.startTranscription(oldest.id, configuration: .default)
        try await store.finishTranscription(original, result: result("older saved transcript"), error: nil)
        await store.releaseAudio(oldest.id)
        for _ in 0..<104 {
            let capture = try await recording()
            await store.releaseAudio(capture.id)
        }
        let model = HistoryViewModel(store: store)
        await model.refresh()
        XCTAssertEqual(model.entries.count, 50)
        await model.refresh(loadMore: true)
        XCTAssertEqual(model.entries.count, 100)
        await model.refresh(loadMore: true)
        XCTAssertEqual(model.entries.count, 105)
        XCTAssertFalse(model.hasMore)

        let expiring = try await store.countRecordingsExpiring(retention: .sevenDays, now: Date().addingTimeInterval(8 * 86400))
        XCTAssertEqual(expiring, 105, "Retention checks must include every row, beyond the first loaded page")
        await model.select(oldest.id)

        let retry = try await store.startTranscription(oldest.id, configuration: .default)
        try await store.finishTranscription(retry, result: result("retried older recording"), error: nil)
        await model.refresh()
        XCTAssertEqual(model.entries.count, 105)
        XCTAssertEqual(model.selectedID, oldest.id)
        XCTAssertEqual(model.detail?.transcriptions.count, 2)
        XCTAssertEqual(model.entries.first { $0.id == oldest.id }?.preview, "retried older recording")
        XCTAssertFalse(model.hasMore)


    }

    @MainActor
    func testUnavailableCardDoesNotRemainInLoadingState() async throws {
        let capture = try await recording()
        await store.releaseAudio(capture.id)
        let model = HistoryViewModel(store: store)
        await model.refresh()
        try await store.delete(capture.id)
        await model.toggleSelection(capture.id)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.detail)
        XCTAssertNotNil(model.errorMessage)
    }

    func testWarmCapturePersistenceLatency() async throws {
        try await store.initialize()
        var samples: [Double] = []
        for _ in 0..<20 {
            let capture = try await store.prepareCapture(retention: .sevenDays)
            try writeAudio(capture.fileURL)
            let started = ContinuousClock.now
            try await store.markFinishing(capture.id)
            _ = try await store.finishCapture(capture.id, capture: DictationCapture(fileURL: capture.fileURL, duration: 1, capturedAt: Date()))
            _ = try await store.startTranscription(capture.id, configuration: .default)
            let elapsed = started.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            await store.releaseAudio(capture.id)
        }
        samples.sort()
        print("History warm finalization persistence: median \(samples[10]) ms, p95 \(samples[18]) ms")
        XCTAssertLessThan(samples[18], 500, "Persistence should not block the pipeline for hundreds of milliseconds")
    }

    func testRetriesPreserveResultsAndRefinementRelationship() async throws {
        let capture = try await recording()
        let first = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(first, result: result("first raw text"), error: nil)
        let refinement = try await store.startRefinement(first, configuration: .default, prompt: "preserve meaning")
        let refined = TranscriptRefinementResult(originalText: "first raw text", refinedText: "First polished text.", model: .qwen3Small, mode: .smartCleanup, completedAt: Date())
        try await store.finishRefinement(refinement, result: refined, error: nil)
        let retry = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(retry, result: result("second raw text"), error: nil)
        let detail = try await store.detail(capture.id)
        XCTAssertEqual(detail.transcriptions.count, 2)
        XCTAssertEqual(detail.refinements.first?.transcriptionID, first)
        let entries = try await store.entries(search: "", limit: 50, offset: 0)
        XCTAssertEqual(entries.first?.preview, "second raw text", "An older refinement must not mask a newer Whisper result")
        let matches = try await store.entries(search: "polished", limit: 50, offset: 0)
        XCTAssertEqual(matches.count, 1, "Search includes previous refined text")
    }

    func testCancelledCaptureNeverAppearsOrRecovers() async throws {
        let capture = try await store.prepareCapture(retention: .sevenDays)
        try writeAudio(capture.fileURL)
        try await store.discardCapture(capture.id)
        let reopened = SQLiteHistoryStore(root: root)
        try await reopened.initialize()
        let entries = try await reopened.entries(search: "", limit: 50, offset: 0)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.fileURL.path))
    }

    func testRecoveryDiscardsUnfinishedCaptureAndRecoversFinishIntent() async throws {
        let cancelled = try await store.prepareCapture(retention: .sevenDays)
        try writeAudio(cancelled.fileURL)
        let completed = try await store.prepareCapture(retention: .sevenDays)
        try writeAudio(completed.fileURL)
        try await store.markFinishing(completed.id)
        let reopened = SQLiteHistoryStore(root: root)
        try await reopened.initialize()
        let entries = try await reopened.entries(search: "", limit: 50, offset: 0)
        XCTAssertEqual(entries.map(\.id), [completed.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.fileURL.path))
        XCTAssertTrue(entries[0].duration > 0)
    }

    func testActiveAudioPreventsDeletionAndExpiryUntilReleased() async throws {
        let capture = try await recording()
        await store.releaseAudio(capture.id)
        let url = try await store.acquireAudio(capture.id)
        do { try await store.deleteAll(); XCTFail("Active audio must prevent deletion") }
        catch HistoryStoreError.inUse {}
        try await store.cleanup(now: Date().addingTimeInterval(8 * 86400))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        await store.releaseAudio(capture.id)
        try await store.cleanup(now: Date().addingTimeInterval(8 * 86400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        do { _ = try await store.detail(capture.id); XCTFail("Expired row should be gone") }
        catch HistoryStoreError.unavailable {}
    }

    func testDeleteCascadesAndLateCompletionCannotRecreateEntry() async throws {
        let capture = try await recording()
        let attempt = try await store.startTranscription(capture.id, configuration: .default)
        await store.releaseAudio(capture.id)
        try await store.delete(capture.id)
        do { try await store.finishTranscription(attempt, result: result("late"), error: nil); XCTFail("Late result must be rejected") }
        catch HistoryStoreError.unavailable {}
        let entries = try await store.entries(search: "", limit: 50, offset: 0)
        XCTAssertTrue(entries.isEmpty)
    }

    func testOffDoesNotEraseHistoryAndRetentionDoesNotDependOnRetryTime() async throws {
        let capture = try await recording()
        let original = try await store.detail(capture.id)
        try await store.setRetention(.off)
        let off = try await store.detail(capture.id)
        XCTAssertEqual(off.entry.expiresAt, original.entry.expiresAt)
        try await store.setRetention(.fourteenDays)
        let extended = try await store.detail(capture.id)
        XCTAssertEqual(extended.entry.expiresAt.timeIntervalSince(extended.entry.capturedAt), 14 * 86400, accuracy: 0.01)
        _ = try await store.startTranscription(capture.id, configuration: .default)
        let afterRetry = try await store.detail(capture.id)
        XCTAssertEqual(afterRetry.entry.expiresAt, extended.entry.expiresAt)
    }

    func testRecoveryMarksRunningAttemptInterruptedAndPreservesRawText() async throws {
        let capture = try await recording()
        let transcription = try await store.startTranscription(capture.id, configuration: .default)
        try await store.finishTranscription(transcription, result: result("saved raw"), error: nil)
        _ = try await store.startRefinement(transcription, configuration: .default, prompt: "prompt")
        let reopened = SQLiteHistoryStore(root: root)
        try await reopened.initialize()
        let detail = try await reopened.detail(capture.id)
        XCTAssertEqual(detail.transcriptions.first?.result?.text, "saved raw")
        XCTAssertEqual(detail.refinements.first?.status, .interrupted)
    }

    func testOffPreservesFourteenDayExpiryUntilSevenDaysIsApplied() async throws {
        let capture = try await recording()
        await store.releaseAudio(capture.id)
        try await store.setRetention(.fourteenDays)
        let extended = try await store.detail(capture.id)
        try await store.setRetention(.off)
        try await store.cleanup(now: extended.entry.capturedAt.addingTimeInterval(8 * 86400))
        let retained = try await store.detail(capture.id)
        XCTAssertEqual(retained.entry.expiresAt, extended.entry.expiresAt)
        let now = retained.entry.capturedAt.addingTimeInterval(8 * 86400)
        let offCount = try await store.countRecordingsExpiring(retention: .off, now: now)
        let fourteenDayCount = try await store.countRecordingsExpiring(retention: .fourteenDays, now: now)
        let sevenDayCount = try await store.countRecordingsExpiring(retention: .sevenDays, now: now)
        XCTAssertEqual(offCount, 0)
        XCTAssertEqual(fourteenDayCount, 0)
        XCTAssertEqual(sevenDayCount, 1)

        try await store.setRetention(.sevenDays)
        let shortened = try await store.detail(capture.id)
        XCTAssertEqual(shortened.entry.expiresAt.timeIntervalSince(shortened.entry.capturedAt), 7 * 86400, accuracy: 0.01)
        try await store.cleanup(now: shortened.entry.capturedAt.addingTimeInterval(8 * 86400))
        let entries = try await store.entries(search: "", limit: 50, offset: 0)
        XCTAssertTrue(entries.isEmpty)
    }

    func testAttemptStatusesRoundTripThroughStorage() async throws {
        let capture = try await recording()
        let unprocessed = try await store.detail(capture.id)
        XCTAssertEqual(unprocessed.entry.status, .unprocessed)
        let attempt = try await store.startTranscription(capture.id, configuration: .default)
        let running = try await store.detail(capture.id)
        XCTAssertEqual(running.entry.status, .running)
        XCTAssertEqual(running.transcriptions.first?.status, .running)
        try await store.finishTranscription(attempt, result: result("saved"), error: nil)
        let succeeded = try await store.detail(capture.id)
        XCTAssertEqual(succeeded.entry.status, .succeeded)
        XCTAssertEqual(succeeded.transcriptions.first?.status, .succeeded)
        let refinement = try await store.startRefinement(attempt, configuration: .default, prompt: "prompt")
        try await store.finishRefinement(refinement, result: nil, error: "Synthetic failure")
        let failed = try await store.detail(capture.id)
        XCTAssertEqual(failed.refinements.first?.status, .failed)
    }
}
