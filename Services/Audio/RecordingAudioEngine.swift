import AVFoundation
import Foundation
import OSLog

// AVAudioEngine setup, hardware start/stop, and file finalization can block.
// Own the graph on one serial queue, never the UI or the audio callback thread.
final class RecordingAudioEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dictaflow.recording-engine", qos: .userInitiated)
    private let relay = RecordingInputRelay()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DictaFlow", category: "AudioCapture")
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var fileURL: URL?
    private var configurationObserver: NSObjectProtocol?
    private var isShutDown = false

    var captureError: Error? { relay.captureError }
    var currentPowerLevel: Double { relay.currentPowerLevel }

    func perform<T: Sendable>(_ operation: @escaping @Sendable (RecordingAudioEngine) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard !isShutDown else { throw CancellationError() }
                    continuation.resume(returning: try operation(self))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func prepareEngine() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard fileURL == nil else { return }
        if relay.needsRebuild { releaseEngine() }
        guard engine == nil else { return }
        let began = ProcessInfo.processInfo.systemUptime
        let engine = AVAudioEngine()
        do {
            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min
            )
            input.isVoiceProcessingAGCEnabled = false
            let rate = input.outputFormat(forBus: 0).sampleRate
            guard rate > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let cueFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
                throw AudioRecorderServiceError.failedToPrepare
            }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: cueFormat)
            // Voice Processing I/O requires matching mono client formats. The
            // aggregate device layout can also contain non-microphone channels.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
            let relay = self.relay
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(ceil(rate * 0.1)), format: format) { buffer, _ in
                relay.append(buffer)
            }
            guard input.outputFormat(forBus: 0) == engine.outputNode.inputFormat(forBus: 0) else {
                throw AudioRecorderServiceError.voiceProcessingUnavailable
            }
            engine.prepare()
            self.engine = engine
            self.player = player
            self.format = format
            relay.resetConfiguration()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { _ in
                // Do not tear down the engine on its internal notification thread.
                relay.invalidateConfiguration()
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
            logger.info("Audio engine prepared in \(elapsed, privacy: .public) ms; hardware running: \(engine.isRunning, privacy: .public)")
        } catch {
            engine.stop()
            logger.error("Could not prepare voice processing: \(String(describing: error), privacy: .public)")
            throw AudioRecorderServiceError.voiceProcessingUnavailable
        }
    }

    func prepareCapture() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard fileURL == nil else { throw AudioRecorderServiceError.alreadyRecording }
        try prepareEngine()
        guard let format else { throw AudioRecorderServiceError.failedToPrepare }
        let url = try makeRecordingURL()
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            do { try secureRecordingFile(at: url) }
            catch { throw AudioRecorderServiceError.temporaryFileProtectionFailed }
            relay.activate(try RecordingAudioBufferSink(file: file, format: format))
            fileURL = url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func startCapture() throws -> URL {
        dispatchPrecondition(condition: .onQueue(queue))
        if fileURL == nil { try prepareCapture() }
        guard let engine, let fileURL else { throw AudioRecorderServiceError.failedToPrepare }
        let began = ProcessInfo.processInfo.systemUptime
        do {
            if let error = relay.captureError { throw error }
            try engine.start()
            guard engine.isRunning else { throw AudioRecorderServiceError.failedToStart }
            if let error = relay.captureError { throw error }
        } catch {
            try? discardCapture()
            releaseEngine()
            logger.error("Could not start recording: \(String(describing: error), privacy: .public)")
            throw error
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        logger.info("Audio hardware started in \(elapsed, privacy: .public) ms")
        return fileURL
    }

    func finishCapture() throws -> DictationCapture {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let url = fileURL, let engine else { throw AudioRecorderServiceError.notRecording }
        // pause stops hardware while retaining prepared resources. Keep the tap
        // installed so changing the graph does not invalidate those resources.
        engine.pause()
        player?.stop()
        fileURL = nil
        guard let sink = relay.deactivate() else { throw AudioRecorderServiceError.notRecording }
        do {
            let duration = try sink.finish()
            logger.info("Recording ended; idle hardware running: \(engine.isRunning, privacy: .public)")
            return DictationCapture(fileURL: url, duration: duration, capturedAt: Date())
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func discardCapture() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let url = fileURL else { throw AudioRecorderServiceError.notRecording }
        engine?.pause()
        player?.stop()
        fileURL = nil
        _ = try? relay.deactivate()?.finish()
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw AudioRecorderServiceError.temporaryFileDeletionFailed }
        }
        logger.info("Recording discarded; idle hardware running: \(self.engine?.isRunning == true, privacy: .public)")
    }

    func playCue(_ buffer: SoundCuePlaybackBuffer, completion: @escaping @Sendable () -> Void) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard fileURL != nil, engine?.isRunning == true, let player else {
            throw SoundCueServiceError.playbackFailed
        }
        buffer.schedule(on: player, completion: completion)
        player.play()
        let outputLatency = (engine?.outputNode.presentationLatency ?? 0) * 1_000
        logger.info("Start cue scheduled; output presentation latency: \(outputLatency, privacy: .public) ms")
    }

    func stopCue() {
        queue.async { [self] in player?.stop() }
    }

    func shutdown() {
        queue.sync {
            isShutDown = true
            try? discardCapture()
            releaseEngine()
        }
    }

    private func releaseEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        player = nil
        engine = nil
        format = nil
    }

    private func makeRecordingURL() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("DictaFlowRecordings", isDirectory: true)

        try ensureRecordingDirectoryExists(at: directoryURL)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename = "capture-\(timestamp)-\(UUID().uuidString.lowercased()).m4a"
        return directoryURL.appendingPathComponent(filename)
    }

    private func ensureRecordingDirectoryExists(at directoryURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )

            let resourceValues = try directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else {
                throw AudioRecorderServiceError.temporaryDirectoryCreationFailed
            }

            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw AudioRecorderServiceError.temporaryDirectoryCreationFailed
        }
    }

    private func secureRecordingFile(at fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )

        var excludedURL = fileURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try excludedURL.setResourceValues(resourceValues)
    }
}

// Only the current capture sink and device-invalidated flag cross queues. While
// paused, the tap has no sink, so no idle audio is buffered or written anywhere.
private final class RecordingInputRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: RecordingAudioBufferSink?
    private var invalidated = false

    var needsRebuild: Bool { lock.withLock { invalidated } }
    var captureError: Error? { lock.withLock { sink }?.recordingError }
    var currentPowerLevel: Double { lock.withLock { sink }?.currentPowerLevel ?? 0 }

    func activate(_ sink: RecordingAudioBufferSink) {
        let changed = lock.withLock {
            self.sink = sink
            return invalidated
        }
        if changed { sink.fail(with: AudioRecorderServiceError.audioDeviceChanged) }
    }
    func deactivate() -> RecordingAudioBufferSink? {
        lock.withLock {
            let previous = sink
            sink = nil
            return previous
        }
    }
    func resetConfiguration() { lock.withLock { invalidated = false } }
    func invalidateConfiguration() {
        let active = lock.withLock {
            invalidated = true
            return sink
        }
        active?.fail(with: AudioRecorderServiceError.audioDeviceChanged)
    }
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { sink }?.append(buffer) }
}
