import XCTest
@testable import DictaFlow_Dev

@MainActor
final class HistorySearchTests: XCTestCase {
    func testLateQueryCannotReplaceNewerSearchResults() async {
        let oldStarted = expectation(description: "Original query starts")
        let newStarted = expectation(description: "New query starts")
        let store = DeferredHistorySearchStore { query in
            if query.isEmpty { oldStarted.fulfill() } else { newStarted.fulfill() }
        }
        let model = HistoryViewModel(store: store)
        let oldTask = Task { await model.refresh() }
        await fulfillment(of: [oldStarted], timeout: 2)
        model.updateSearchQuery("new query")
        let newTask = Task { await model.refresh() }
        await fulfillment(of: [newStarted], timeout: 2)
        let current = entry("New matching result")
        await store.complete("new query", result: .success([current]))
        await newTask.value
        await store.complete("", result: .success([entry("Old unrelated result")]))
        await oldTask.value
        XCTAssertEqual(model.entries.map(\.id), [current.id])
        XCTAssertEqual(model.searchQuery, "new query")
        XCTAssertFalse(model.isLoading)
        let request = await store.range(for: "new query")
        XCTAssertEqual(request?.limit, 50)
        XCTAssertEqual(request?.offset, 0)
    }

    func testLateFailureDoesNotClearNewSearchLoadingOrPublishAnOldError() async {
        let oldStarted = expectation(description: "Original query starts")
        let newStarted = expectation(description: "New query starts")
        let store = DeferredHistorySearchStore { query in
            if query.isEmpty { oldStarted.fulfill() } else { newStarted.fulfill() }
        }
        let model = HistoryViewModel(store: store)
        let oldTask = Task { await model.refresh() }
        await fulfillment(of: [oldStarted], timeout: 2)
        model.updateSearchQuery("latest")
        let newTask = Task { await model.refresh() }
        await fulfillment(of: [newStarted], timeout: 2)
        await store.complete("", result: .failure(HistoryStoreError.unavailable))
        await oldTask.value
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.errorMessage)
        let current = entry("Latest result")
        await store.complete("latest", result: .success([current]))
        await newTask.value
        XCTAssertEqual(model.entries.map(\.id), [current.id])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    private func entry(_ preview: String) -> HistoryEntry {
        HistoryEntry(id: UUID(), capturedAt: Date(), duration: 1, expiresAt: Date().addingTimeInterval(3600),
                     preview: preview, status: .succeeded, audioAvailable: false)
    }
}

/// Holds queries independently to exercise out-of-order completion without timing sleeps.
private actor DeferredHistorySearchStore: HistoryStoreProtocol {
    let onRequest: @Sendable (String) -> Void
    private var pending: [String: CheckedContinuation<[HistoryEntry], Error>] = [:]
    private var ranges: [String: (limit: Int, offset: Int)] = [:]

    init(onRequest: @escaping @Sendable (String) -> Void) { self.onRequest = onRequest }
    func entries(search: String, limit: Int, offset: Int) async throws -> [HistoryEntry] {
        ranges[search] = (limit, offset)
        return try await withCheckedThrowingContinuation { continuation in
            pending[search] = continuation
            onRequest(search)
        }
    }
    func complete(_ query: String, result: Result<[HistoryEntry], Error>) { pending.removeValue(forKey: query)?.resume(with: result) }
    func range(for query: String) -> (limit: Int, offset: Int)? { ranges[query] }

    func initialize() async throws {}
    func releaseAudio(_ id: UUID) async {}
    func cleanup(now: Date) async throws {}
    func prepareCapture(retention: HistoryRetention) async throws -> HistoryCapture { throw HistoryStoreError.unavailable }
    func markFinishing(_ id: UUID) async throws { throw HistoryStoreError.unavailable }
    func finishCapture(_ id: UUID, capture: DictationCapture) async throws -> URL { throw HistoryStoreError.unavailable }
    func discardCapture(_ id: UUID) async throws { throw HistoryStoreError.unavailable }
    func acquireRecording(_ id: UUID) async throws { throw HistoryStoreError.unavailable }
    func captureURL(_ id: UUID) async throws -> URL { throw HistoryStoreError.unavailable }
    func acquireAudio(_ id: UUID) async throws -> URL { throw HistoryStoreError.unavailable }
    func startTranscription(_ id: UUID, configuration: WhisperConfiguration) async throws -> UUID { throw HistoryStoreError.unavailable }
    func finishTranscription(_ attemptID: UUID, result: WhisperTranscriptionResult?, error: String?) async throws { throw HistoryStoreError.unavailable }
    func startRefinement(_ transcriptionID: UUID, configuration: RefinementConfiguration, prompt: String) async throws -> UUID { throw HistoryStoreError.unavailable }
    func finishRefinement(_ attemptID: UUID, result: TranscriptRefinementResult?, error: String?) async throws { throw HistoryStoreError.unavailable }
    func detail(_ id: UUID) async throws -> HistoryDetail { throw HistoryStoreError.unavailable }
    func delete(_ id: UUID) async throws { throw HistoryStoreError.unavailable }
    func deleteAll() async throws { throw HistoryStoreError.unavailable }
    func countRecordingsExpiring(retention: HistoryRetention, now: Date) async throws -> Int { throw HistoryStoreError.unavailable }
    func setRetention(_ retention: HistoryRetention) async throws { throw HistoryStoreError.unavailable }
}
