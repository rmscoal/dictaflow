import Combine
import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var detail: HistoryDetail?
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var hasMore = false
    @Published private(set) var isPlaybackLoading = false
    @Published var retryMessages: [UUID: String] = [:]
    @Published var errorMessage: String?
    @Published var selectedTranscriptionID: UUID?
    @Published var selectedRefinementID: UUID?
    @Published var showsOriginal = false
    let player = HistoryAudioPlayer()
    private let store: HistoryStoreProtocol?
    private var playbackID: UUID?
    private var playbackGeneration = 0
    private var loadGeneration = 0
    private var selectionGeneration = 0
    private var cleanupTimer: Timer?

    init(store: HistoryStoreProtocol?) {
        self.store = store
        player.onFinished = { [weak self] in Task { await self?.stopPlayback() } }
    }

    deinit { cleanupTimer?.invalidate() }

    var transcription: HistoryTranscription? {
        detail?.transcriptions.first { $0.id == selectedTranscriptionID }
    }

    var refinement: HistoryRefinement? {
        detail?.refinements.first { $0.id == selectedRefinementID && $0.transcriptionID == selectedTranscriptionID }
    }

    var refinements: [HistoryRefinement] {
        detail?.refinements.filter { $0.transcriptionID == selectedTranscriptionID } ?? []
    }

    var displayedText: String? {
        let text = showsOriginal ? transcription?.result?.text : refinement?.result?.refinedText
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    func transcriptionLabel(_ result: HistoryTranscription) -> String {
        let attempts = detail?.transcriptions ?? []
        guard let index = attempts.firstIndex(where: { $0.id == result.id }) else { return "Transcription" }
        let number = attempts.count - index
        let title = number == 1 ? "First attempt" : "Attempt \(number)"
        return title + (index == 0 ? " · Latest" : " · Previous")
    }

    func refinementLabel(_ result: HistoryRefinement) -> String {
        guard let index = refinements.firstIndex(where: { $0.id == result.id }) else { return "Refinement" }
        let number = refinements.count - index
        let title = number == 1 ? "First refinement" : "Refinement \(number)"
        return title + (index == 0 ? " · Latest" : " · Previous")
    }

    func start() {
        guard let store else { return }
        Task {
            do {
                try await store.initialize()
                try await store.cleanup(now: Date())
                await refresh()
            } catch { report(error) }
        }
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.cleanup() }
        }
    }

    func shutdown() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        player.stop()
    }

    func report(_ error: Error) {
        if (error as NSError).domain == "com.apple.coreaudio.avfaudio" {
            errorMessage = "History: The saved audio could not be read. You can still use its saved text or delete the recording."
        } else {
            errorMessage = "History: \(error.localizedDescription)"
        }
    }

    func refresh(loadMore: Bool = false) async {
        guard let store else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let appendsPage = loadMore
        let offset = appendsPage ? entries.count : 0
        // The store bounds each query. Refresh all previously loaded pages so
        // retrying an older recording does not remove its card from the feed.
        let pageCount = appendsPage ? 1 : max(1, (entries.count + 49) / 50)
        isLoading = true
        do {
            var refreshed: [HistoryEntry] = []
            var lastPageCount = 0
            for _ in 0..<pageCount {
                let page = try await store.entries(search: "", limit: 50, offset: offset + refreshed.count)
                guard generation == loadGeneration else { return }
                refreshed += page
                lastPageCount = page.count
                if page.count < 50 { break }
            }
            entries = appendsPage ? entries + refreshed : refreshed
            hasMore = lastPageCount == 50
            isLoading = false
            if let selectedID {
                if entries.contains(where: { $0.id == selectedID }) {
                    await select(selectedID, preserveSelection: true)
                } else {
                    await clearSelection()
                }
            }
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            report(error)
        }
    }

    func toggleSelection(_ id: UUID) async {
        if selectedID == id {
            await clearSelection()
        } else {
            await select(id)
        }
    }

    func select(_ id: UUID, preserveSelection: Bool = false) async {
        guard let store else { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        let changesRecording = id != selectedID
        selectedID = id
        if changesRecording {
            detail = nil
            await stopPlayback()
        }
        guard generation == selectionGeneration else { return }
        do {
            let loaded = try await store.detail(id)
            guard generation == selectionGeneration, selectedID == id else { return }
            detail = loaded
            if !preserveSelection || !loaded.transcriptions.contains(where: { $0.id == selectedTranscriptionID }) {
                selectedTranscriptionID = loaded.transcriptions.first(where: { $0.result != nil })?.id ?? loaded.transcriptions.first?.id
                selectTranscription()
            } else if !loaded.refinements.contains(where: { $0.id == selectedRefinementID }) {
                selectTranscription()
            }
        } catch {
            guard generation == selectionGeneration else { return }
            report(error)
            await clearSelection()
        }
    }

    func selectTranscription() {
        selectedRefinementID = refinements.first(where: { $0.result != nil })?.id ?? refinements.first?.id
        showsOriginal = refinement?.result == nil
    }

    private func clearSelection() async {
        selectionGeneration += 1
        selectedID = nil
        detail = nil
        selectedTranscriptionID = nil
        selectedRefinementID = nil
        await stopPlayback()
    }

    func togglePlayback() async {
        guard let store, let selectedID else { return }
        if playbackID == selectedID { player.togglePause(); return }
        guard !isPlaybackLoading else { return }
        isPlaybackLoading = true
        defer { isPlaybackLoading = false }
        await stopPlayback()
        let generation = playbackGeneration
        do {
            let url = try await store.acquireAudio(selectedID)
            guard self.selectedID == selectedID, generation == playbackGeneration else { await store.releaseAudio(selectedID); return }
            playbackID = selectedID
            do { try player.play(url: url) }
            catch { await stopPlayback(); throw error }
        } catch { report(error) }
    }

    func stopPlayback() async {
        playbackGeneration += 1
        player.stop()
        let id = playbackID
        playbackID = nil
        if let id { await store?.releaseAudio(id) }
    }

    func deleteSelected() async {
        guard let store, let selectedID, !isMutating else { return }
        isMutating = true
        await stopPlayback()
        do {
            try await store.delete(selectedID)
            await clearSelection()
            await refresh()
        } catch { report(error); await refresh() }
        isMutating = false
    }

    func deleteAll() async {
        guard let store, !isMutating else { return }
        isMutating = true
        await stopPlayback()
        do {
            try await store.deleteAll()
            await clearSelection()
            await refresh()
        } catch { report(error); await refresh() }
        isMutating = false
    }

    func cleanup() async {
        guard let store else { return }
        do { try await store.cleanup(now: Date()); await refresh() }
        catch { report(error) }
    }
}
