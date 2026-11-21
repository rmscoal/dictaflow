import AgentVoice
import AVFoundation
import Combine
import Foundation
import OSLog

@MainActor
protocol AgentSpeechPlayerProtocol: AnyObject {
    func play(_ wav: Data, rate: Double, onStart: () -> Void) async throws
    func setRate(_ rate: Double)
    func stop()
}

enum AgentVoicePreviewState: Equatable, Sendable {
    case idle, generating, playing, stopping
    case failed(String)
}

/// Explicit actionable Agent Voice error. Views switch on `scope`, never on
/// message text, so raw authorization and resource messages stay visible
/// without substring matching. Set only at real failure points; cleared only
/// by an explicit user action or a later success, never by heartbeats,
/// refreshes, or routine status updates.
struct AgentVoiceError: Equatable, Sendable {
    enum Scope: String, Equatable, Sendable { case setup, models, playback }
    let scope: Scope
    let message: String
}

@MainActor
final class AgentSpeechPlayer: NSObject, AgentSpeechPlayerProtocol, AVAudioPlayerDelegate {
    private struct Playback {
        let player: AVAudioPlayer
        let completion: CheckedContinuation<Void, Error>
    }

    private var active: Playback?
    private var timeout: Task<Void, Never>?

    func play(_ wav: Data, rate: Double, onStart: () -> Void) async throws {
        try Task.checkCancellation()
        guard active == nil else { throw VoiceError.unavailable("Agent speech is already playing.") }
        let player = try AVAudioPlayer(data: wav)
        player.delegate = self
        player.enableRate = true
        player.rate = Float(rate)
        try await withCheckedThrowingContinuation { continuation in
            active = Playback(player: player, completion: continuation)
            guard player.prepareToPlay(), player.play() else {
                finish(player, error: VoiceError.unavailable("Could not play agent speech."))
                return
            }
            // The delegate handles completion at the actual rate, including live edits.
            // Bound the wait in case the audio device never sends a callback.
            let limit = player.duration / AgentVoiceCoordinator.playbackRateRange.lowerBound + 2
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(limit)) }
                catch { return }
                self?.finish(player, error: VoiceError.unavailable("Agent speech playback did not finish. Check your Mac’s sound output."))
            }
            onStart()
        }
    }

    func setRate(_ rate: Double) { active?.player.rate = Float(rate) }

    func stop() {
        guard let active else { return }
        finish(active.player, error: CancellationError())
    }

    private func finish(_ player: AVAudioPlayer, error: Error? = nil) {
        guard let playback = active, playback.player === player else { return }
        active = nil
        timeout?.cancel()
        timeout = nil
        player.delegate = nil
        player.stop()
        if let error { playback.completion.resume(throwing: error) }
        else { playback.completion.resume() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.finish(player, error: flag ? nil : VoiceError.unavailable("Could not finish playing agent speech."))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.finish(player, error: error ?? VoiceError.unavailable("Could not decode agent speech for playback."))
        }
    }
}

/// App-owned boundary for MCP, queue execution, playback, and foreground inference priority.
/// Dictation's recording state machine remains in DictaFlowAppState.
@MainActor
final class AgentVoiceCoordinator: ObservableObject {
    static let playbackRateRange = 0.75...1.5
    private static let speechVoiceKey = "agentVoice.speechVoice"
    private static let englishAccentKey = "agentVoice.englishAccent"
    private static let playbackRateKey = "agentVoice.playbackRate"
    private static let previewText = """
        Here's a sample of how your agent might sound during a longer reply. \
        The first three steps are complete, and there's one small detail to check before we wrap up. \
        Once that's done, we can save the result, write a short summary, and move on to the next task. \
        Does this pace give you enough time to follow each point?
        """

    @Published private(set) var isEnabled: Bool
    @Published private(set) var status = "Agent Voice is off."
    @Published private(set) var isModelReady = false
    @Published private(set) var modelDownloadProgress: ModelDownloadProgress?
    var isDownloading: Bool { modelDownloadProgress != nil }
    var onModelDownloadFinished: ((Result<Void, Error>) -> Void)?
    @Published private(set) var drafts: [VoiceDraft] = []
    @Published private(set) var history: [VoiceHistoryRecord] = []
    @Published private(set) var admissionPolicy: VoiceAdmissionPolicy = .automatic
    @Published private(set) var activeSource: String?
    @Published private(set) var isForegroundBusy = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var isGenerating = false
    @Published private(set) var speechVoice: LiquidVoice
    @Published private(set) var englishAccent: LiquidEnglishAccent
    @Published private(set) var playbackRate: Double
    @Published private(set) var previewState: AgentVoicePreviewState = .idle
    @Published private(set) var activeError: AgentVoiceError?
    @Published private(set) var replayError: String?
    private var rejectedRenditionID: UUID?

    let assets: LiquidAssets
    private let modelDownloader: any LiquidAssetDownloading
    private var modelDownloadTask: Task<Void, Never>?
    private var modelDownloadGeneration = UUID()
    let runtime: any LiquidRuntimeProtocol
    let installationID: UUID
    let appID: String
    var prepareSpeechResources: (() async -> Void)?
    private let defaults: UserDefaults
    private let player: AgentSpeechPlayerProtocol
    private let beforeIdleRefresh: (() async -> Void)?
    private let beforeRetentionRefresh: ((VoiceHistoryRetention) async -> Void)?
    private let beforePreviewCompletion: (() -> Void)?
    private let logger = Logger(subsystem: "com.dictaflow.agentvoice", category: "Coordinator")
    private var store: VoiceStore?
    private var bridge: LocalVoiceServer?
    private var worker: Task<Void, Never>?
    private var workerNeedsWake = false
    private var previewTask: Task<AgentVoicePreviewState, Never>?
    private var synthesisTask: Task<LiquidSpeech, Error>?
    private var maintenance: Task<Void, Never>?
    private var resourceRelease: Task<Void, Never>?
    private var activeJob: UUID?
    private var activeInput: UUID?
    private var foregroundLeases: Set<UUID> = []
    private var generation = UUID()
    private var stopped = false

    init(defaults: UserDefaults = .standard, player: AgentSpeechPlayerProtocol? = nil,
         supportDirectory: URL? = nil, runtime: (any LiquidRuntimeProtocol)? = nil, appIdentity: String? = nil,
         limits: VoiceLimits = VoiceLimits(), beforeIdleRefresh: (() async -> Void)? = nil,
         beforeRetentionRefresh: ((VoiceHistoryRetention) async -> Void)? = nil,
         modelDownloader: (any LiquidAssetDownloading)? = nil, beforePreviewCompletion: (() -> Void)? = nil) {
        self.defaults = defaults; self.player = player ?? AgentSpeechPlayer()
        speechVoice = defaults.string(forKey: Self.speechVoiceKey).flatMap(LiquidVoice.init(rawValue:)) ?? .female
        englishAccent = defaults.string(forKey: Self.englishAccentKey).flatMap(LiquidEnglishAccent.init(rawValue:)) ?? .american
        let savedRate = defaults.double(forKey: Self.playbackRateKey)
        playbackRate = Self.playbackRateRange.contains(savedRate) ? savedRate : 1
        self.beforeIdleRefresh = beforeIdleRefresh
        self.beforeRetentionRefresh = beforeRetentionRefresh
        self.beforePreviewCompletion = beforePreviewCompletion
        appID = appIdentity ?? (Bundle.main.bundleIdentifier == "com.dictaflow" ? "com.dictaflow" : "com.dictaflow.dev")
        let name = appID == "com.dictaflow" ? "DictaFlow" : "DictaFlow Dev"
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        assets = LiquidAssets(directory: support.appendingPathComponent("Models/Liquid/\(LiquidAssets.revision)"))
        self.modelDownloader = modelDownloader ?? assets
        self.runtime = runtime ?? LiquidRuntime(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AudioRuntime/llama-server"), assets: assets)
        let installation = defaults.string(forKey: "agentVoice.installationID").flatMap(UUID.init(uuidString:)) ?? UUID()
        installationID = installation; defaults.set(installation.uuidString, forKey: "agentVoice.installationID")
        isEnabled = defaults.bool(forKey: "agentVoice.enabled")
        do { store = try VoiceStore(url: support.appendingPathComponent("AgentVoice/voice.sqlite"), limits: limits) }
        catch {
            status = "Agent Voice storage failed: \(error.localizedDescription)"
            activeError = AgentVoiceError(scope: .setup, message: status)
            isEnabled = false
        }
        if isEnabled { startBridge() }
        if let store {
            maintenance = Task { [weak self, weak store] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(60))
                        guard let self, let store else { return }
                        if try await store.performMaintenance() { await self.didReceiveRequest() }
                    } catch is CancellationError {
                        return
                    } catch {
                        self?.reportStorageError(error)
                    }
                }
            }
        }
        Task { [weak self, modelDownloader = self.modelDownloader, generation = modelDownloadGeneration] in
            await self?.refresh()
            let ready = (try? await modelDownloader.isReady()) == true
            guard self?.modelDownloadGeneration == generation else { return }
            self?.isModelReady = ready
        }
    }

    var connectionCommand: String {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dictaflow-mcp").path
        return "\"\(executable)\" --app-id \(appID) --installation-id \(installationID.uuidString) --host codex"
    }

    func setEnabled(_ enabled: Bool) {
        guard !stopped else { return }
        // An explicit toggle supersedes every prior actionable error. Fresh
        // failures below set a new one; heartbeats and refreshes never clear.
        activeError = nil
        defaults.set(enabled, forKey: "agentVoice.enabled"); isEnabled = enabled
        if enabled { startBridge() }
        else {
            bridge?.stop(); bridge = nil; interruptActiveSpeech()
            Task { [weak self, store] in
                do { try await store?.cancelAll(); await self?.refresh() }
                catch {
                    self?.status = error.localizedDescription
                    self?.activeError = AgentVoiceError(scope: .setup, message: error.localizedDescription)
                }
            }
            status = "Agent Voice is off."
        }
    }

    func downloadModel() {
        guard !stopped, !isDownloading else { return }
        // An explicit retry supersedes a prior model error; other scopes stay.
        if activeError?.scope == .models { activeError = nil }
        let generation = UUID()
        modelDownloadGeneration = generation
        modelDownloadProgress = ModelDownloadProgress(progress: nil, statusText: "Starting download")
        status = "Downloading and verifying Liquid audio (1.4 GB)…"
        modelDownloadTask = Task { [weak self, modelDownloader] in
            // Consume callbacks in order, including verification, before publishing the outcome.
            let (events, continuation) = AsyncStream.makeStream(of: LiquidDownloadEvent.self, bufferingPolicy: .bufferingNewest(1))
            let updates = Task { @MainActor [weak self] in
                for await event in events {
                    guard let self, self.modelDownloadGeneration == generation else { continue }
                    self.applyModelDownloadEvent(event)
                }
            }
            var outcome: Result<Void, Error>?
            do {
                try await modelDownloader.download { continuation.yield($0) }
                try Task.checkCancellation()
                outcome = .success(())
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    outcome = .failure(error)
                }
            }
            continuation.finish()
            await updates.value
            if Task.isCancelled { outcome = nil }
            guard let self else { return }
            self.modelDownloadTask = nil
            self.modelDownloadProgress = nil
            switch outcome {
            case .success:
                self.isModelReady = true
                self.status = "Liquid audio is ready."
            case .failure(let error):
                let message = "Liquid download failed: \(error.localizedDescription)"
                self.status = message
                self.activeError = AgentVoiceError(scope: .models, message: message)
            case nil:
                self.status = "Liquid download cancelled. Any verified files are kept for retry."
            }
            if let outcome, !self.stopped { self.onModelDownloadFinished?(outcome) }
        }
    }

    func cancelModelDownload() {
        modelDownloadTask?.cancel()
    }

    private func applyModelDownloadEvent(_ event: LiquidDownloadEvent) {
        switch event {
        case .downloading(let bytesWritten, let totalBytes):
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            modelDownloadProgress = ModelDownloadProgress(
                progress: totalBytes > 0 ? min(1, max(0, Double(bytesWritten) / Double(totalBytes))) : nil,
                statusText: "\(formatter.string(fromByteCount: bytesWritten)) of \(formatter.string(fromByteCount: totalBytes))"
            )
        case .verifying:
            modelDownloadProgress = ModelDownloadProgress(progress: nil, statusText: "Verifying speech model…")
        }
    }

    /// Synchronous local silence precedes any microphone await. Tokens span the full pipeline.
    func acquireForeground() -> UUID {
        let firstLease = foregroundLeases.isEmpty
        let lease = UUID(); foregroundLeases.insert(lease)
        isForegroundBusy = true
        interruptActiveSpeech(suppress: firstLease, reason: "Agent speech interrupted for dictation.")
        return lease
    }

    func releaseForeground(_ lease: UUID) {
        foregroundLeases.remove(lease)
        isForegroundBusy = !foregroundLeases.isEmpty
        pump()
    }

    func waitForForegroundResources() async throws {
        let started = ContinuousClock.now
        await resourceRelease?.value
        guard await runtime.hasExited() else { throw VoiceError.unavailable("Liquid audio has not stopped. The recording is kept; try transcription again.") }
        logger.info("Foreground resource_wait_seconds=\(Self.seconds(since: started), privacy: .public)")
    }

    func speak(_ draft: VoiceDraft) {
        guard isEnabled, let store else { return }
        let requestedAt = ContinuousClock.now
        Task { [weak self] in
            do {
                _ = try await store.authorizeByUser(draftID: draft.id)
                self?.logger.info("Speech admission_seconds=\(Self.seconds(since: requestedAt), privacy: .public)")
                // Authorized Play is a valid action: it clears a stale playback error.
                if self?.activeError?.scope == .playback { self?.activeError = nil }
                await self?.refresh(); self?.pump()
            }
            catch {
                self?.status = error.localizedDescription
                self?.activeError = AgentVoiceError(scope: .playback, message: error.localizedDescription)
                // A rejected Play must refresh so a stale, expired, or deleted
                // row updates its eligibility instead of staying playable.
                await self?.refresh()
            }
        }
    }

    func stopSpeech() { interruptActiveSpeech(suppress: true) }

    /// Stops the playback shown in one bubble and continues unrelated queued speech.
    func stopPlayback(attemptID: UUID) async {
        guard let store else { return }
        do {
            let cancelled = try await store.stopPlayback(attemptID: attemptID)
            if activeJob == attemptID {
                // An expired attempt can still own an in-flight runtime call.
                interruptActiveSpeech()
            } else if !cancelled { return }
            await refresh()
            pump()
        } catch { reportPlaybackError(error) }
    }

    /// Suppresses a ready interaction so the overlay and queue move on.
    func dismissReadyInteraction(_ id: UUID) {
        guard let store else { return }
        Task { [weak self] in
            do {
                try await store.suppressInteraction(inputID: id)
                await self?.didReceiveRequest()
            } catch { self?.reportPlaybackError(error) }
        }
    }

    /// Clears the retained replay error and its rejected rendition.
    func dismissReplayError() {
        replayError = nil
        rejectedRenditionID = nil
    }

    func setAdmissionPolicy(_ policy: VoiceAdmissionPolicy) {
        guard let store else { return }
        if policy == .manualOnly { interruptActiveSpeech() }
        Task { [weak self] in
            do {
                try await store.setAdmissionPolicy(policy)
                await self?.refresh()
                self?.pump()
            } catch { self?.reportPlaybackError(error) }
        }
    }

    func setSpeechVoice(_ voice: LiquidVoice) {
        guard speechVoice != voice else { return }
        speechVoice = voice
        defaults.set(voice.rawValue, forKey: Self.speechVoiceKey)
        speechSynthesisSettingsDidChange()
    }

    func setEnglishAccent(_ accent: LiquidEnglishAccent) {
        guard englishAccent != accent else { return }
        englishAccent = accent
        defaults.set(accent.rawValue, forKey: Self.englishAccentKey)
        speechSynthesisSettingsDidChange()
    }

    private func speechSynthesisSettingsDidChange() {
        synthesisTask?.cancel()
        if previewState == .playing {
            previewState = .generating
            player.stop()
        }
    }

    func setPlaybackRate(_ rate: Double) {
        guard Self.playbackRateRange.contains(rate), playbackRate != rate else { return }
        playbackRate = rate
        defaults.set(rate, forKey: Self.playbackRateKey)
        player.setRate(rate)
    }

    var canPreviewVoice: Bool {
        isEnabled && isModelReady && !isForegroundBusy && !isGenerating && !isSpeaking && !stopped
    }

    func previewVoice() {
        guard canPreviewVoice else { return }
        switch previewState {
        case .idle, .failed:
            previewState = .generating
            pump()
        case .generating, .playing, .stopping:
            break
        }
    }

    func stopVoicePreview() {
        guard previewState == .generating || previewState == .playing else { return }
        guard let previewTask else {
            previewState = .idle
            return
        }
        previewState = .stopping
        previewTask.cancel()
        synthesisTask?.cancel()
        player.stop()
    }

    /// Queues a rendition for manual playback, retaining any rejection for display until retried.
    func playRendition(_ id: UUID) async {
        guard isEnabled, let store else { return }
        do {
            _ = try await store.requestManualPlayback(renditionID: id)
            if rejectedRenditionID == id { dismissReplayError() }
            if activeError?.scope == .playback { activeError = nil }
            await refresh()
            pump()
        } catch {
            reportPlaybackError(error)
            rejectedRenditionID = id
            replayError = error.localizedDescription
            await refresh()
        }
    }

    func deleteInteraction(_ id: UUID) {
        guard let store else { return }
        if activeInput == id { interruptActiveSpeech() }
        Task { [weak self] in
            do {
                _ = try await store.deleteInteraction(inputID: id)
                await self?.refresh()
            } catch { self?.reportPlaybackError(error) }
            self?.pump()
        }
    }

    /// Deletes every interaction in a session (prompts, revisions, attempts,
    /// events) with a single refresh. Interrupts active speech first when the
    /// session owns it.
    func deleteInteractions(_ ids: [UUID]) {
        guard let store, !ids.isEmpty else { return }
        if let active = activeInput, ids.contains(active) { interruptActiveSpeech() }
        Task { [weak self] in
            do {
                for id in ids { _ = try await store.deleteInteraction(inputID: id) }
                await self?.refresh()
            } catch { self?.reportPlaybackError(error) }
            self?.pump()
        }
    }

    /// Counts interactions a proposed voice retention would delete, for the
    /// shorten-retention confirm dialog, including deferred deletion after playback.
    func countVoiceInteractionsExpiring(_ retention: VoiceHistoryRetention) async throws -> Int {
        guard let store else { throw VoiceError.unavailable("Agent Voice storage is unavailable.") }
        return try await store.countInteractionsExpiring(retention: retention.retentionInterval, now: Date())
    }

    /// Applies a voice retention selection to the store and refreshes history.
    /// Retention changes never interrupt active speech: prune skips
    /// interactions with active attempts.
    func setVoiceHistoryRetention(_ retention: VoiceHistoryRetention) async throws {
        guard let store else { throw VoiceError.unavailable("Agent Voice storage is unavailable.") }
        try await store.setHistoryRetentionInterval(retention.retentionInterval)
        await beforeRetentionRefresh?(retention)
        await refresh()
    }

    /// Prunes expired voice history after a retention change and refreshes.
    func pruneVoiceHistory() async {
        guard let store else { return }
        do {
            _ = try await store.pruneHistory(now: Date())
            await refresh()
        } catch { reportStorageError(error) }
    }

    private func reportPlaybackError(_ error: Error) {
        status = error.localizedDescription
        activeError = AgentVoiceError(scope: .playback, message: status)
    }

    func recognize(_ audioURL: URL, configuration: WhisperConfiguration) async throws -> WhisperTranscriptionResult {
        try Self.preflightAudioReadable(audioURL)
        let samples = try await AVAudioDecodingService().decodePCMFloatSamples(from: audioURL)
        // Recordings that fit one request keep the single-request path; only longer
        // recordings pay for a chunk boundary. The energy scan runs off MainActor.
        let chunks: [Range<Int>]
        if Double(samples.count) / 16_000 <= LiquidRuntime.maxASRDuration {
            chunks = [0..<samples.count]
        } else {
            chunks = await Task.detached(priority: .userInitiated) {
                LiquidAudioChunker.split(samples: samples, sampleRate: 16_000)
            }.value
        }
        guard !chunks.isEmpty else { throw VoiceError.unavailable("The recorded audio is empty.") }
        let translateToEnglish = configuration.taskMode == .translateToEnglish
        do {
            var texts: [String] = []
            texts.reserveCapacity(chunks.count)
            for chunk in chunks {
                try Task.checkCancellation()
                texts.append(try await transcribeChunk(samples: samples, range: chunk, translateToEnglish: translateToEnglish))
            }
            await runtime.stop()
            return WhisperTranscriptionResult(text: texts.joined(separator: " "), segments: [], detectedLanguageCode: translateToEnglish ? "en" : nil,
                                              model: nil, taskMode: configuration.taskMode, completedAt: Date(), recognitionProvider: .liquid)
        } catch {
            updateReadiness(after: error)
            await runtime.stop()
            throw error
        }
    }

    /// Transcribes one chunk with the shared warm sidecar. Each chunk is its
    /// own request, so the per-request guards in
    /// `LiquidRuntime.validateASRInput` apply per chunk, not per recording.
    private func transcribeChunk(samples: [Float], range: Range<Int>, translateToEnglish: Bool) async throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)),
              let channel = buffer.floatChannelData?[0] else { throw VoiceError.unavailable("Could not prepare recorded audio for Liquid recognition.") }
        buffer.frameLength = AVAudioFrameCount(range.count)
        samples[range].withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: range.count) }
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            try file.write(from: buffer)
        }
        return try await runtime.transcribe(wav: Data(contentsOf: temporary), translateToEnglish: translateToEnglish)
    }

    /// Marks the Liquid model not ready when the runtime reports its assets unavailable.
    private func updateReadiness(after error: Error) {
        // The runtime has just verified the pinned files. Avoid rehashing the
        // same failed assets before presenting the Download button.
        if let error = error as? VoiceError, case .liquidModelUnavailable = error {
            isModelReady = false
        }
    }

    /// Metadata-only readability check before the potentially unbounded full
    /// decode. Missing or unreadable files propagate the decoder's existing
    /// error. Invalid or nonfinite durations fail explicitly. Long recordings
    /// are chunked in `recognize`, so there is no duration cap here; each
    /// chunk still passes the per-request guards in the runtime.
    private static func preflightAudioReadable(_ audioURL: URL) throws {
        let file = try AVAudioFile(forReading: audioURL)
        let rate = file.processingFormat.sampleRate
        let frames = Double(file.length)
        guard rate.isFinite, rate > 0, frames.isFinite, frames >= 0 else {
            throw VoiceError.unavailable("Liquid could not read the recording length.")
        }
        let duration = frames / rate
        guard duration.isFinite else { throw VoiceError.unavailable("Liquid could not read the recording length.") }
    }

    func shutdown() {
        stopped = true; bridge?.stop(); bridge = nil
        cancelModelDownload()
        maintenance?.cancel(); maintenance = nil
        interruptActiveSpeech(stopAllInference: true)
    }

    func waitForShutdown() async {
        await modelDownloadTask?.value
        await resourceRelease?.value
    }

    private func startBridge() {
        guard bridge == nil, let store else { return }
        let bridge = LocalVoiceServer(socketURL: VoicePaths.socketURL(appID: appID), handler: { [weak self] request, connection in
            guard await self?.isEnabled == true else { return VoiceReply(accepted: false, code: "disabled") }
            do {
                let reply = try await store.handle(request, connectionID: connection)
                if request.operation != .heartbeat { await self?.didReceiveRequest() }
                if reply.code == "stop_observed_queue_full" {
                    await self?.reportPlaybackError(VoiceError.unavailable("The speech queue is full. This response is saved in History for Play."))
                } else if reply.code == "stop_observed_stale_rendition" {
                    await self?.reportPlaybackError(VoiceError.unavailable("This response is too old for automatic speech. Use Play in History."))
                }
                return reply
            } catch { return VoiceReply(accepted: false, code: "storage_failed", message: "DictaFlow could not persist the request. Finish your written answer normally.") }
        }, onDisconnect: { [weak self] connection in
            try? await store.disconnect(connectionID: connection)
            await self?.didReceiveRequest()
        })
        do {
            try bridge.start(); self.bridge = bridge
            status = "Agent Voice is ready for connected hosts."
            if activeError?.scope == .setup { activeError = nil }
        } catch {
            status = error.localizedDescription
            activeError = AgentVoiceError(scope: .setup, message: status)
            isEnabled = false; defaults.set(false, forKey: "agentVoice.enabled")
        }
    }

    private func didReceiveRequest() async {
        if let job = activeJob {
            let isActive = (try? await store?.isActiveAttempt(job)) == true
            // A committed correction can invalidate audio already on the
            // player. Stop when the store cannot confirm it is still current.
            if activeJob == job, !isActive { interruptActiveSpeech() }
        }
        await refresh()
        pump()
    }

    private func refresh() async {
        do {
            drafts = try await store?.drafts().sorted { $0.createdAt > $1.createdAt } ?? []
            history = try await store?.historyRecords(limit: 500) ?? []
            admissionPolicy = try await store?.admissionPolicy() ?? .automatic
        }
        catch { reportStorageError(error) }
        // Success never clears: heartbeat and routine refreshes must not
        // hide an actionable error set by a real failure.
    }

    /// Publishes a storage failure as the coordinator's setup error status.
    func reportStorageError(_ error: Error) {
        status = "Agent Voice storage failed: \(error.localizedDescription)"
        activeError = AgentVoiceError(scope: .setup, message: status)
    }

    private func interruptActiveSpeech(stopAllInference: Bool = false, suppress: Bool = false,
                                       reason: String = "Agent speech stopped.") {
        // Captured synchronously; the store resolves every other target
        // itself at execution time, so attempts admitted after this frame's
        // last refresh are still suppressed.
        let suppressedInput = suppress ? activeInput : nil
        generation = UUID()
        stopVoicePreview()
        synthesisTask?.cancel()
        player.stop(); isSpeaking = false; isGenerating = false
        worker?.cancel()
        let oldWorker = worker; worker = nil
        let job = activeJob; activeJob = nil
        activeInput = nil; activeSource = nil
        if job != nil { status = reason }
        let shouldStopRuntime = oldWorker != nil || job != nil || stopAllInference
        let priorRelease = resourceRelease
        resourceRelease = Task { [weak self, runtime, store] in
            await priorRelease?.value
            if suppress {
                do { _ = try await store?.suppressActiveSpeech(for: suppressedInput) }
                catch { self?.reportPlaybackError(error) }
            }
            if let job {
                _ = try? await store?.transition(job, from: .synthesizing, to: .cancelled)
                _ = try? await store?.transition(job, from: .playing, to: .cancelled)
            }
            if shouldStopRuntime { await runtime.stop() }
            await oldWorker?.value
            await self?.refresh()
        }
    }

    private func pump() {
        guard isEnabled, !stopped, foregroundLeases.isEmpty, let store else { return }
        if worker != nil { workerNeedsWake = true; return }
        let token = generation
        let release = resourceRelease
        worker = Task { [weak self] in
            guard let self else { return }
            await release?.value
            defer {
                if generation == token {
                    worker = nil; activeJob = nil; activeInput = nil; activeSource = nil
                    isSpeaking = false; isGenerating = false
                }
            }
            while !Task.isCancelled, generation == token, foregroundLeases.isEmpty, isEnabled {
                do {
                    workerNeedsWake = false
                    if previewState == .generating {
                        await runVoicePreview()
                        continue
                    }
                    guard let job = try await store.nextJob() else {
                        await beforeIdleRefresh?()
                        await refresh()
                        if workerNeedsWake { continue }
                        return
                    }
                    guard !Task.isCancelled, generation == token, foregroundLeases.isEmpty else {
                        _ = try? await store.transition(job.id, from: .synthesizing, to: .cancelled)
                        return
                    }
                    activeJob = job.id; activeInput = job.inputID
                    activeSource = "\(job.session.host) · \(job.session.sessionID.prefix(8))"
                    isGenerating = true; status = "Generating agent speech…"
                    await refresh()
                    let processingStarted = ContinuousClock.now
                    await prepareSpeechResources?()
                    logger.info("Speech resource_preparation_seconds=\(Self.seconds(since: processingStarted), privacy: .public)")
                    guard !Task.isCancelled, generation == token, foregroundLeases.isEmpty else { return }
                    let speech = try await synthesizeWithCurrentSettings(job.text)
                    guard !Task.isCancelled, generation == token, foregroundLeases.isEmpty,
                          try await store.transition(job.id, from: .synthesizing, to: .playing) else { continue }
                    await refresh()
                    guard !Task.isCancelled, generation == token, foregroundLeases.isEmpty else { return }
                    let playerStarted = ContinuousClock.now
                    try await player.play(speech.wav, rate: playbackRate) {
                        self.isGenerating = false
                        self.isSpeaking = true
                        self.status = "Speaking agent response."
                        self.logger.info("Speech processing_to_player_start_seconds=\(Self.seconds(since: processingStarted), privacy: .public) player_start_seconds=\(Self.seconds(since: playerStarted), privacy: .public)")
                    }
                    guard !Task.isCancelled, generation == token else { return }
                    isSpeaking = false
                    _ = try await store.transition(job.id, from: .playing, to: .completed)
                    guard !Task.isCancelled, generation == token else { return }
                    activeJob = nil; status = "Agent speech finished."
                    if activeError?.scope == .playback { activeError = nil }
                    await refresh()
                } catch {
                    if generation != token { return }
                    updateReadiness(after: error)
                    let failedJob = activeJob
                    if let activeJob {
                        _ = try? await store.transition(activeJob, from: .synthesizing, to: .failed, failure: error.localizedDescription)
                        _ = try? await store.transition(activeJob, from: .playing, to: .failed, failure: error.localizedDescription)
                    }
                    player.stop(); isSpeaking = false; isGenerating = false; status = "Agent speech failed: \(error.localizedDescription)"
                    activeError = AgentVoiceError(scope: .playback, message: status)
                    await refresh()
                    activeJob = nil
                    if failedJob == nil { return }
                    continue
                }
            }
        }
    }

    private func synthesizeWithCurrentSettings(_ text: String) async throws -> LiquidSpeech {
        while true {
            try Task.checkCancellation()
            let voice = speechVoice
            let accent = englishAccent
            let task = Task { [runtime] in
                try await runtime.synthesize(text, voice: voice, englishAccent: accent)
            }
            synthesisTask = task
            let result = await task.result
            // Release model compute before playback or another synthesis.
            await runtime.stop()
            synthesisTask = nil
            try Task.checkCancellation()
            if voice == speechVoice, accent == englishAccent, !task.isCancelled { return try result.get() }
        }
    }

    private func runVoicePreview() async {
        let task = Task { [self] () -> AgentVoicePreviewState in
            do {
                await prepareSpeechResources?()
                repeat {
                    let speech = try await synthesizeWithCurrentSettings(Self.previewText)
                    try Task.checkCancellation()
                    do {
                        try await player.play(speech.wav, rate: playbackRate) { previewState = .playing }
                    } catch is CancellationError where previewState == .generating {
                        // A voice or accent change stopped the sample so it can play with the new settings.
                    }
                } while previewState == .generating
                return .idle
            } catch is CancellationError {
                return .idle
            } catch {
                updateReadiness(after: error)
                return .failed(error.localizedDescription)
            }
        }
        previewTask = task
        let result = await task.value
        beforePreviewCompletion?()
        previewTask = nil
        // A settings change between completion and cleanup can request another preview.
        if previewState == .generating, result == .idle { return }
        previewState = previewState == .stopping ? .idle : result
    }

    private static func seconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}
