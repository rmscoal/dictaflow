import AgentVoice
import AVFoundation
import Combine
import Foundation
import OSLog

@MainActor
protocol AgentSpeechPlayerProtocol: AnyObject {
    func play(_ wav: Data) throws -> TimeInterval
    func stop()
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
final class AgentSpeechPlayer: AgentSpeechPlayerProtocol {
    private var player: AVAudioPlayer?
    func play(_ wav: Data) throws -> TimeInterval {
        let player = try AVAudioPlayer(data: wav)
        guard player.prepareToPlay(), player.play() else { throw VoiceError.unavailable("Could not play agent speech.") }
        self.player = player
        return player.duration
    }
    func stop() { player?.stop(); player = nil }
}

/// App-owned boundary for MCP, queue execution, playback, and foreground inference priority.
/// Dictation's recording state machine remains in DictaFlowAppState.
@MainActor
final class AgentVoiceCoordinator: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var status = "Agent Voice is off."
    @Published private(set) var isModelReady = false
    @Published private(set) var isDownloading = false
    @Published private(set) var drafts: [VoiceDraft] = []
    @Published private(set) var history: [VoiceHistoryRecord] = []
    @Published private(set) var admissionPolicy: VoiceAdmissionPolicy = .automatic
    @Published private(set) var activeSource: String?
    @Published private(set) var isForegroundBusy = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var isGenerating = false
    @Published private(set) var activeError: AgentVoiceError?

    let assets: LiquidAssets
    let runtime: any LiquidRuntimeProtocol
    let installationID: UUID
    let appID: String
    var prepareSpeechResources: (() async -> Void)?
    private let defaults: UserDefaults
    private let player: AgentSpeechPlayerProtocol
    private let logger = Logger(subsystem: "com.dictaflow.agentvoice", category: "Coordinator")
    private var store: VoiceStore?
    private var bridge: LocalVoiceServer?
    private var worker: Task<Void, Never>?
    private var resourceRelease: Task<Void, Never>?
    private var activeJob: UUID?
    private var activeInput: UUID?
    private var foregroundLeases: Set<UUID> = []
    private var generation = UUID()
    private var stopped = false

    init(defaults: UserDefaults = .standard, player: AgentSpeechPlayerProtocol? = nil,
         supportDirectory: URL? = nil, runtime: (any LiquidRuntimeProtocol)? = nil, appIdentity: String? = nil,
         limits: VoiceLimits = VoiceLimits()) {
        self.defaults = defaults; self.player = player ?? AgentSpeechPlayer()
        appID = appIdentity ?? (Bundle.main.bundleIdentifier == "com.dictaflow" ? "com.dictaflow" : "com.dictaflow.dev")
        let name = appID == "com.dictaflow" ? "DictaFlow" : "DictaFlow Dev"
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        assets = LiquidAssets(directory: support.appendingPathComponent("Models/Liquid/\(LiquidAssets.revision)"))
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
        Task { [weak self, assets] in
            await self?.refresh()
            self?.isModelReady = (try? await assets.isReady()) == true
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
        guard !isDownloading else { return }
        // An explicit retry supersedes a prior model error; other scopes stay.
        if activeError?.scope == .models { activeError = nil }
        isDownloading = true; status = "Downloading and verifying Liquid audio (1.4 GB)…"
        Task { [weak self, assets] in
            do {
                try await assets.download()
                self?.isModelReady = true
                self?.status = "Liquid audio is ready."
            } catch {
                let message = "Liquid download failed: \(error.localizedDescription)"
                self?.status = message
                self?.activeError = AgentVoiceError(scope: .models, message: message)
            }
            self?.isDownloading = false
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

    func playRendition(_ id: UUID) {
        guard isEnabled, let store else { return }
        Task { [weak self] in
            do {
                _ = try await store.requestManualPlayback(renditionID: id)
                if self?.activeError?.scope == .playback { self?.activeError = nil }
                await self?.refresh()
                self?.pump()
            } catch { self?.reportPlaybackError(error); await self?.refresh() }
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
        }
    }

    private func reportPlaybackError(_ error: Error) {
        status = error.localizedDescription
        activeError = AgentVoiceError(scope: .playback, message: status)
    }

    func recognize(_ audioURL: URL, configuration: WhisperConfiguration) async throws -> WhisperTranscriptionResult {
        try Self.preflightASRDuration(audioURL)
        let samples = try await AVAudioDecodingService().decodePCMFloatSamples(from: audioURL)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw VoiceError.unavailable("Could not prepare recorded audio for Liquid recognition.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings)
            try file.write(from: buffer)
        }
        do {
            let text = try await runtime.transcribe(wav: Data(contentsOf: temporary), english: configuration.taskMode == .translateToEnglish)
            await runtime.stop()
            return WhisperTranscriptionResult(text: text, segments: [], detectedLanguageCode: configuration.taskMode == .translateToEnglish ? "en" : nil,
                                              model: nil, taskMode: configuration.taskMode, completedAt: Date(), recognitionProvider: .liquid)
        } catch { await runtime.stop(); throw error }
    }

    /// Metadata-only duration check before the potentially unbounded full decode.
    /// Missing or unreadable files propagate the decoder's existing error. Invalid
    /// or nonfinite durations fail explicitly. Overlimit clips fail with retention
    /// so the user can retry with Whisper; they are never truncated or switched.
    private static func preflightASRDuration(_ audioURL: URL) throws {
        let file = try AVAudioFile(forReading: audioURL)
        let rate = file.processingFormat.sampleRate
        let frames = Double(file.length)
        guard rate.isFinite, rate > 0, frames.isFinite, frames >= 0 else {
            throw VoiceError.unavailable("Liquid could not read the recording length.")
        }
        let duration = frames / rate
        guard duration.isFinite else { throw VoiceError.unavailable("Liquid could not read the recording length.") }
        guard duration <= LiquidRuntime.maxASRDuration else {
            throw VoiceError.inputTooLong("Liquid ASR supports up to 2 minutes. The recording is kept; use Whisper or a shorter recording.")
        }
    }

    func shutdown() {
        stopped = true; bridge?.stop(); bridge = nil
        interruptActiveSpeech(stopAllInference: true)
    }

    func waitForShutdown() async { await resourceRelease?.value }

    private func startBridge() {
        guard bridge == nil, let store else { return }
        let bridge = LocalVoiceServer(socketURL: VoicePaths.socketURL(appID: appID), handler: { [weak self] request, connection in
            guard await self?.isEnabled == true else { return VoiceReply(accepted: false, code: "disabled") }
            do {
                let reply = try await store.handle(request, connectionID: connection)
                await self?.didReceiveRequest()
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
        await refresh()
        if let activeJob, !history.contains(where: { record in
            record.attempts.contains { $0.id == activeJob && !$0.state.isTerminal }
        }) { interruptActiveSpeech() }
        pump()
    }

    private func refresh() async {
        do {
            drafts = try await store?.drafts().sorted { $0.createdAt > $1.createdAt } ?? []
            history = try await store?.historyRecords(limit: 500) ?? []
            admissionPolicy = try await store?.admissionPolicy() ?? .automatic
        }
        catch {
            status = "Agent Voice storage failed: \(error.localizedDescription)"
            activeError = AgentVoiceError(scope: .setup, message: status)
        }
        // Success never clears: heartbeat and routine refreshes must not
        // hide an actionable error set by a real failure.
    }

    private func interruptActiveSpeech(stopAllInference: Bool = false, suppress: Bool = false,
                                       reason: String = "Agent speech stopped.") {
        // Captured synchronously; the store resolves every other target
        // itself at execution time, so attempts admitted after this frame's
        // last refresh are still suppressed.
        let suppressedInput = suppress ? activeInput : nil
        generation = UUID()
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
        guard isEnabled, !stopped, foregroundLeases.isEmpty, worker == nil, let store else { return }
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
                    guard let job = try await store.nextJob() else { await refresh(); return }
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
                    let speech = try await runtime.synthesize(job.text)
                    // Retire model compute before playback or foreground inference.
                    await runtime.stop()
                    guard !Task.isCancelled, generation == token, foregroundLeases.isEmpty,
                          try await store.transition(job.id, from: .synthesizing, to: .playing) else { continue }
                    guard !Task.isCancelled, generation == token, foregroundLeases.isEmpty else { return }
                    let playerStarted = ContinuousClock.now
                    let duration = try player.play(speech.wav)
                    isGenerating = false; isSpeaking = true; status = "Speaking agent response."
                    await refresh()
                    logger.info("Speech processing_to_player_start_seconds=\(Self.seconds(since: processingStarted), privacy: .public) player_start_seconds=\(Self.seconds(since: playerStarted), privacy: .public)")
                    try await Task.sleep(for: .seconds(duration))
                    player.stop(); isSpeaking = false
                    _ = try await store.transition(job.id, from: .playing, to: .completed)
                    activeJob = nil; status = "Agent speech finished."
                    if activeError?.scope == .playback { activeError = nil }
                    await refresh()
                } catch {
                    if generation != token { return }
                    let failedJob = activeJob
                    if let activeJob {
                        _ = try? await store.transition(activeJob, from: .synthesizing, to: .failed, failure: error.localizedDescription)
                        _ = try? await store.transition(activeJob, from: .playing, to: .failed, failure: error.localizedDescription)
                    }
                    player.stop(); isSpeaking = false; isGenerating = false; status = "Agent speech failed: \(error.localizedDescription)"
                    activeError = AgentVoiceError(scope: .playback, message: status)
                    await runtime.stop(); await refresh()
                    activeJob = nil
                    if failedJob == nil { return }
                    continue
                }
            }
        }
    }

    private static func seconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}
