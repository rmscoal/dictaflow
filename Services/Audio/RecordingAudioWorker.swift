import AVFoundation
import CoreAudio
import Foundation
import OSLog

// Recorder preparation, hardware control, and AAC finalization can block.
// Keep them on one queue; the UI reads only the lock-protected status snapshot.
nonisolated final class RecordingAudioWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dictaflow.audio-recorder", qos: .userInitiated)
    private let status = RecordingAudioStatus()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DictaFlow", category: "AudioCapture")
    private var recorder: AVAudioRecorder?
    private var recorderDelegate: RecordingAudioDelegate?
    private var fileURL: URL?
    private var session: UUID?
    private var meteringTimer: DispatchSourceTimer?
    private var inputDeviceObserver: AudioObjectPropertyListenerBlock?
    private var inputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    private var isShutDown = false

    var captureError: Error? { status.error }
    var currentPowerLevel: Double { status.powerLevel }

    func perform<T: Sendable>(_ operation: @escaping @Sendable (RecordingAudioWorker) throws -> T) async throws -> T {
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

    func prepareCapture(at destination: URL? = nil) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard fileURL == nil else { throw AudioRecorderServiceError.alreadyRecording }
        let began = ProcessInfo.processInfo.systemUptime
        var preparedURL: URL?
        do {
            let url = try destination ?? makeRecordingURL()
            preparedURL = url
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            self.recorder = recorder
            let session = UUID()
            self.session = session
            status.prepare(session: session)
            let delegate = RecordingAudioDelegate(status: status, session: session)
            recorderDelegate = delegate
            recorder.delegate = delegate
            recorder.isMeteringEnabled = true
            try observeInputDevice(session: session)
            guard recorder.prepareToRecord() else { throw AudioRecorderServiceError.failedToPrepare }
            do { try secureRecordingFile(at: url) }
            catch { throw AudioRecorderServiceError.temporaryFileProtectionFailed }
            if let error = status.error { throw error }
            fileURL = url
            let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
            logger.info("Audio recorder prepared in \(elapsed, privacy: .public) ms")
        } catch {
            releaseRecorder()
            if let preparedURL { try? FileManager.default.removeItem(at: preparedURL) }
            logger.error("Could not prepare microphone input: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func startCapture() throws -> URL {
        dispatchPrecondition(condition: .onQueue(queue))
        if fileURL == nil { try prepareCapture() }
        guard let recorder, let fileURL else { throw AudioRecorderServiceError.failedToPrepare }
        guard !recorder.isRecording else { throw AudioRecorderServiceError.alreadyRecording }
        let began = ProcessInfo.processInfo.systemUptime
        do {
            if let error = status.error { throw error }
            status.beginCapture()
            guard recorder.record(), recorder.isRecording else { throw AudioRecorderServiceError.failedToStart }
            startMetering()
            if let error = status.error { throw error }
        } catch {
            try? discardCapture()
            logger.error("Could not start recording: \(String(describing: error), privacy: .public)")
            throw error
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        logger.info("Audio hardware started in \(elapsed, privacy: .public) ms")
        return fileURL
    }

    func finishCapture() throws -> DictationCapture {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let url = fileURL else {
            releaseRecorder()
            throw AudioRecorderServiceError.notRecording
        }
        let captureError = status.error
        let stoppedUnexpectedly = recorder?.isRecording != true
        let finalizationError = releaseRecorder()
        fileURL = nil
        do {
            if let captureError { throw captureError }
            if let finalizationError { throw finalizationError }
            if stoppedUnexpectedly { throw AudioRecorderServiceError.audioDeviceChanged }
            // stop() finalizes AAC before the file is handed to transcription.
            let audioFile = try AVAudioFile(forReading: url)
            guard audioFile.length > 0, audioFile.processingFormat.sampleRate > 0 else {
                throw AudioRecorderServiceError.failedToWrite
            }
            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            logger.info("Recording ended; audio recorder released")
            return DictationCapture(fileURL: url, duration: duration, capturedAt: Date())
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func discardCapture() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        releaseRecorder()
        let url = fileURL
        fileURL = nil
        guard let url else { throw AudioRecorderServiceError.notRecording }
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw AudioRecorderServiceError.temporaryFileDeletionFailed }
        }
        logger.info("Recording discarded; audio recorder released")
    }

    func shutdown() {
        queue.sync {
            isShutDown = true
            try? discardCapture()
        }
    }

    private func startMetering() {
        updateMetering()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.updateMetering() }
        meteringTimer = timer
        timer.resume()
    }

    private func updateMetering() {
        guard let recorder, let session else { return }
        guard recorder.isRecording else {
            status.fail(with: AudioRecorderServiceError.audioDeviceChanged, session: session)
            return
        }
        recorder.updateMeters()
        let power = Double(recorder.averagePower(forChannel: 0))
        status.updatePower(power.isFinite ? min(max((power + 55) / 55, 0), 1) : 0, session: session)
    }

    private func observeInputDevice(session: UUID) throws {
        let status = self.status
        let observer: AudioObjectPropertyListenerBlock = { _, _ in
            status.fail(with: AudioRecorderServiceError.audioDeviceChanged, session: session)
        }
        let result = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
            &inputDeviceAddress, queue, observer)
        guard result == noErr else { throw AudioRecorderServiceError.failedToPrepare }
        inputDeviceObserver = observer
    }

    @discardableResult
    private func releaseRecorder() -> Error? {
        let hadRecorder = recorder != nil
        let began = ProcessInfo.processInfo.systemUptime
        meteringTimer?.cancel()
        meteringTimer = nil
        if let observer = inputDeviceObserver {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                &inputDeviceAddress, queue, observer)
            inputDeviceObserver = nil
        }
        // A successful stop callback is expected here. Keep encoding errors
        // visible until stop() has finished finalizing the file.
        status.endCapture()
        session = nil
        recorder?.stop()
        let finalizationError = status.error
        status.clear()
        recorder?.delegate = nil
        recorder = nil
        recorderDelegate = nil
        if hadRecorder {
            let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
            logger.info("Audio recorder released in \(elapsed, privacy: .public) ms")
        }
        return finalizationError
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

nonisolated final class RecordingAudioStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var session: UUID?
    private var firstError: Error?
    private var power: Double = 0
    private var isCapturing = false

    var error: Error? { lock.withLock { firstError } }
    var powerLevel: Double { lock.withLock { power } }

    func prepare(session: UUID) {
        lock.withLock { self.session = session; firstError = nil; power = 0; isCapturing = false }
    }
    func beginCapture() { lock.withLock { isCapturing = true } }
    func endCapture() { lock.withLock { isCapturing = false } }
    func clear() {
        lock.withLock { session = nil; firstError = nil; power = 0; isCapturing = false }
    }
    func reportUnexpectedStop(session: UUID) {
        lock.withLock {
            guard self.session == session, isCapturing, firstError == nil else { return }
            firstError = AudioRecorderServiceError.audioDeviceChanged
        }
    }
    func fail(with error: Error, session: UUID) {
        lock.withLock {
            guard self.session == session, firstError == nil else { return }
            firstError = error
        }
    }
    func updatePower(_ power: Double, session: UUID) {
        lock.withLock {
            guard self.session == session else { return }
            self.power = power
        }
    }
}

nonisolated private final class RecordingAudioDelegate: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    private let status: RecordingAudioStatus
    private let session: UUID

    init(status: RecordingAudioStatus, session: UUID) {
        self.status = status
        self.session = session
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if flag { status.reportUnexpectedStop(session: session) }
        else { status.fail(with: AudioRecorderServiceError.failedToWrite, session: session) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        status.fail(with: AudioRecorderServiceError.failedToWrite, session: session)
    }
}
