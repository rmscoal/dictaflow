import AVFoundation
import Foundation

@MainActor
protocol AudioRecorderServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    func startRecording() async throws -> URL
    func stopRecording() async throws -> DictationCapture
}

enum AudioRecorderServiceError: LocalizedError {
    case alreadyRecording
    case notRecording
    case failedToPrepare
    case failedToStart
    case temporaryDirectoryCreationFailed
    case temporaryFileProtectionFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "There is no active recording to stop."
        case .failedToPrepare:
            return "The audio recorder could not be prepared."
        case .failedToStart:
            return "The recorder failed to begin capturing microphone audio."
        case .temporaryDirectoryCreationFailed:
            return "DictaFlow could not create its temporary recording folder."
        case .temporaryFileProtectionFailed:
            return "DictaFlow could not secure its temporary recording file."
        }
    }
}

@MainActor
final class SystemAudioRecorderService: NSObject, AudioRecorderServiceProtocol {
    private var recorder: AVAudioRecorder?
    private var activeRecordingURL: URL?

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    func startRecording() async throws -> URL {
        guard !isRecording else {
            throw AudioRecorderServiceError.alreadyRecording
        }

        let fileURL = try makeRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.isMeteringEnabled = false

        guard recorder.prepareToRecord() else {
            try? FileManager.default.removeItem(at: fileURL)
            throw AudioRecorderServiceError.failedToPrepare
        }

        guard recorder.record() else {
            try? FileManager.default.removeItem(at: fileURL)
            throw AudioRecorderServiceError.failedToStart
        }

        do {
            try secureRecordingFile(at: fileURL)
        } catch {
            recorder.stop()
            try? FileManager.default.removeItem(at: fileURL)
            throw AudioRecorderServiceError.temporaryFileProtectionFailed
        }

        self.recorder = recorder
        self.activeRecordingURL = fileURL
        return fileURL
    }

    func stopRecording() async throws -> DictationCapture {
        guard let recorder, recorder.isRecording, let fileURL else {
            throw AudioRecorderServiceError.notRecording
        }

        recorder.stop()

        let capture = DictationCapture(
            fileURL: fileURL,
            duration: measuredDuration(of: fileURL) ?? recorder.currentTime,
            capturedAt: Date()
        )

        self.recorder = nil
        self.activeRecordingURL = nil
        return capture
    }

    private var fileURL: URL? {
        activeRecordingURL
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

    private func measuredDuration(of fileURL: URL) -> TimeInterval? {
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else {
            return nil
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else {
            return nil
        }

        return TimeInterval(audioFile.length) / sampleRate
    }
}
