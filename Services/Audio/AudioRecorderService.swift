import AVFoundation
import Foundation

@MainActor
protocol AudioRecorderServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    var currentPowerLevel: Double { get }
    var recordingError: Error? { get }
    func warmUp() async throws
    func shutdown()
    func prepareRecording() async throws
    func prepareRecording(at url: URL) async throws
    func startRecording() async throws -> URL
    func stopRecording() async throws -> DictationCapture
    func discardRecording() async throws
}

extension AudioRecorderServiceProtocol {
    var recordingError: Error? { nil }
    func prepareRecording(at url: URL) async throws { try await prepareRecording() }
    func warmUp() async throws {}
}

@MainActor
protocol RecordingCuePlaybackProtocol: AnyObject {
    var isRecording: Bool { get }
    func playRecordingCue(_ buffer: SoundCuePlaybackBuffer, completion: @escaping @Sendable () -> Void) async throws
    func stopRecordingCue()
}

enum AudioRecorderServiceError: LocalizedError {
    case alreadyRecording
    case notRecording
    case failedToPrepare
    case failedToStart
    case voiceProcessingUnavailable
    case audioDeviceChanged
    case failedToWrite
    case temporaryDirectoryCreationFailed
    case temporaryFileProtectionFailed
    case temporaryFileDeletionFailed

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
        case .voiceProcessingUnavailable:
            return "Echo cancellation could not start. Check your microphone and sound output in System Settings, then try again."
        case .audioDeviceChanged:
            return "The audio device changed or stopped. Check your microphone and sound output, then start a new recording."
        case .failedToWrite:
            return "The recording could not be saved completely. Check available disk space, then try again."
        case .temporaryDirectoryCreationFailed:
            return "DictaFlow could not create its temporary recording folder."
        case .temporaryFileProtectionFailed:
            return "DictaFlow could not secure its temporary recording file."
        case .temporaryFileDeletionFailed:
            return "DictaFlow could not delete the cancelled temporary recording."
        }
    }
}

@MainActor
final class SystemAudioRecorderService: AudioRecorderServiceProtocol, RecordingCuePlaybackProtocol {
    private let worker = RecordingAudioEngine()
    private(set) var isRecording = false

    var recordingError: Error? { worker.captureError }
    var currentPowerLevel: Double { isRecording ? worker.currentPowerLevel : 0 }

    func warmUp() async throws {
        try await worker.perform { try $0.prepareEngine() }
    }

    func prepareRecording() async throws {
        try await worker.perform { try $0.prepareCapture() }
    }

    func prepareRecording(at url: URL) async throws {
        try await worker.perform { try $0.prepareCapture(at: url) }
    }

    func startRecording() async throws -> URL {
        let url = try await worker.perform { try $0.startCapture() }
        isRecording = true
        return url
    }

    func stopRecording() async throws -> DictationCapture {
        defer { isRecording = false }
        return try await worker.perform { try $0.finishCapture() }
    }

    func discardRecording() async throws {
        defer { isRecording = false }
        try await worker.perform { try $0.discardCapture() }
    }

    func playRecordingCue(_ buffer: SoundCuePlaybackBuffer, completion: @escaping @Sendable () -> Void) async throws {
        guard isRecording else { throw SoundCueServiceError.playbackFailed }
        try await worker.perform { try $0.playCue(buffer, completion: completion) }
    }

    func stopRecordingCue() {
        worker.stopCue()
    }

    func shutdown() {
        worker.shutdown()
        isRecording = false
    }
}
