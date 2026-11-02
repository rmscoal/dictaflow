import AgentVoice
import AVFoundation
import Combine
import Foundation

@MainActor
protocol AgentSpeechPlayerProtocol: AnyObject {
    func play(_ wav: Data) throws -> TimeInterval
    func stop()
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
    @Published private(set) var isSpeaking = false

    let assets: LiquidAssets
    let runtime: any LiquidRuntimeProtocol
    let installationID: UUID
    let appID: String
    var prepareSpeechResources: (() async -> Void)?
    private let defaults: UserDefaults
    private let player: AgentSpeechPlayerProtocol
    private var store: VoiceStore?
    private var bridge: LocalVoiceServer?
    private var worker: Task<Void, Never>?
    private var resourceRelease: Task<Void, Never>?
    private var activeJob: UUID?
    private var foregroundLeases: Set<UUID> = []
    private var generation = UUID()
    private var stopped = false

    init(defaults: UserDefaults = .standard, player: AgentSpeechPlayerProtocol? = nil,
         supportDirectory: URL? = nil, runtime: (any LiquidRuntimeProtocol)? = nil, appIdentity: String? = nil) {
        self.defaults = defaults; self.player = player ?? AgentSpeechPlayer()
        appID = appIdentity ?? (Bundle.main.bundleIdentifier == "com.dictaflow" ? "com.dictaflow" : "com.dictaflow.dev")
        let name = appID == "com.dictaflow" ? "DictaFlow" : "DictaFlow Dev"
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        assets = LiquidAssets(directory: support.appendingPathComponent("Models/Liquid/\(LiquidAssets.revision)"))
        self.runtime = runtime ?? LiquidRuntime(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AudioRuntime/llama-server"), assets: assets)
        let installation = defaults.string(forKey: "agentVoice.installationID").flatMap(UUID.init(uuidString:)) ?? UUID()
        installationID = installation; defaults.set(installation.uuidString, forKey: "agentVoice.installationID")
        isEnabled = defaults.bool(forKey: "agentVoice.enabled")
        do { store = try VoiceStore(url: support.appendingPathComponent("AgentVoice/voice.sqlite")) }
        catch { status = "Agent Voice storage failed: \(error.localizedDescription)"; isEnabled = false }
        if isEnabled { startBridge() }
        Task { [weak self, assets] in self?.isModelReady = (try? await assets.isReady()) == true }
    }

    var connectionCommand: String {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dictaflow-mcp").path
        return "\"\(executable)\" --app-id \(appID) --installation-id \(installationID.uuidString) --host codex"
    }

    func setEnabled(_ enabled: Bool) {
        guard !stopped else { return }
        defaults.set(enabled, forKey: "agentVoice.enabled"); isEnabled = enabled
        if enabled { startBridge() }
        else {
            bridge?.stop(); bridge = nil; interruptActiveSpeech()
            Task { [weak self, store] in
                do { try await store?.cancelAll(); await self?.refresh() }
                catch { self?.status = error.localizedDescription }
            }
            status = "Agent Voice is off."
        }
    }

    func downloadModel() {
        guard !isDownloading else { return }
        isDownloading = true; status = "Downloading and verifying Liquid audio (1.4 GB)…"
        Task { [weak self, assets] in
            do {
                try await assets.download()
                self?.isModelReady = true
                self?.status = "Liquid audio is ready. Automatic host completion is not qualified."
            } catch { self?.status = "Liquid download failed: \(error.localizedDescription)" }
            self?.isDownloading = false
        }
    }

    /// Synchronous local silence precedes any microphone await. Tokens span the full pipeline.
    func acquireForeground() -> UUID {
        let lease = UUID(); foregroundLeases.insert(lease)
        interruptActiveSpeech(reason: "Agent speech interrupted for dictation.")
        return lease
    }

    func releaseForeground(_ lease: UUID) {
        foregroundLeases.remove(lease)
        pump()
    }

    func waitForForegroundResources() async throws {
        await resourceRelease?.value
        guard await runtime.hasExited() else { throw VoiceError.unavailable("Liquid audio has not stopped. The recording is kept; try transcription again.") }
    }

    func speak(_ draft: VoiceDraft) {
        guard isEnabled, let store else { return }
        Task { [weak self] in
            do { _ = try await store.authorizeByUser(draftID: draft.id); await self?.refresh(); self?.pump() }
            catch { self?.status = error.localizedDescription }
        }
    }

    func stopSpeech() { interruptActiveSpeech() }

    func recognize(_ audioURL: URL, configuration: WhisperConfiguration) async throws -> WhisperTranscriptionResult {
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
                return reply
            } catch { return VoiceReply(accepted: false, code: "storage_failed", message: "DictaFlow could not persist the request. Finish your written answer normally.") }
        }, onDisconnect: { [weak self] connection in
            try? await store.disconnect(connectionID: connection)
            await self?.didReceiveRequest()
        })
        do {
            try bridge.start(); self.bridge = bridge
            status = "Connected locally. Automatic playback awaits host qualification; prepared speech can be played here."
        } catch { status = error.localizedDescription; isEnabled = false; defaults.set(false, forKey: "agentVoice.enabled") }
    }

    private func didReceiveRequest() async {
        await refresh()
        if let activeJob, !drafts.contains(where: { $0.id == activeJob && !$0.state.isTerminal }) { interruptActiveSpeech() }
        pump()
    }

    private func refresh() async {
        do { drafts = try await store?.drafts().sorted { $0.createdAt > $1.createdAt } ?? [] }
        catch { status = "Agent Voice storage failed: \(error.localizedDescription)" }
    }

    private func interruptActiveSpeech(stopAllInference: Bool = false, reason: String = "Agent speech stopped.") {
        generation = UUID()
        player.stop(); isSpeaking = false
        worker?.cancel()
        let oldWorker = worker; worker = nil
        let job = activeJob; activeJob = nil
        if job != nil { status = reason }
        let shouldStopRuntime = oldWorker != nil || job != nil || stopAllInference
        let priorRelease = resourceRelease
        resourceRelease = Task { [weak self, runtime, store] in
            await priorRelease?.value
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
                if generation == token { worker = nil; activeJob = nil; isSpeaking = false }
            }
            while !Task.isCancelled, generation == token, foregroundLeases.isEmpty, isEnabled {
                do {
                    guard let job = try await store.nextJob() else { await refresh(); return }
                    guard !Task.isCancelled, generation == token, foregroundLeases.isEmpty else {
                        _ = try? await store.transition(job.id, from: .synthesizing, to: .cancelled)
                        return
                    }
                    activeJob = job.id; status = "Generating agent speech…"
                    await prepareSpeechResources?()
                    guard !Task.isCancelled, generation == token, foregroundLeases.isEmpty else { return }
                    let speech = try await runtime.synthesize(job.text)
                    // Retire model compute before playback or foreground inference.
                    await runtime.stop()
                    guard !Task.isCancelled, generation == token, foregroundLeases.isEmpty,
                          try await store.transition(job.id, from: .synthesizing, to: .playing) else { continue }
                    guard !Task.isCancelled, generation == token, foregroundLeases.isEmpty else { return }
                    let duration = try player.play(speech.wav)
                    isSpeaking = true; status = "Speaking agent response."
                    try await Task.sleep(for: .seconds(duration))
                    player.stop(); isSpeaking = false
                    _ = try await store.transition(job.id, from: .playing, to: .completed)
                    activeJob = nil; status = "Agent speech finished."
                    await refresh()
                } catch {
                    if generation != token { return }
                    let failedJob = activeJob
                    if let activeJob {
                        _ = try? await store.transition(activeJob, from: .synthesizing, to: .failed, failure: error.localizedDescription)
                        _ = try? await store.transition(activeJob, from: .playing, to: .failed, failure: error.localizedDescription)
                    }
                    player.stop(); isSpeaking = false; status = "Agent speech failed: \(error.localizedDescription)"
                    await runtime.stop(); await refresh()
                    activeJob = nil
                    if failedJob == nil { return }
                    continue
                }
            }
        }
    }
}
