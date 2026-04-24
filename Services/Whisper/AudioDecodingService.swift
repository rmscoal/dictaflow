@preconcurrency import AVFoundation
import Foundation

protocol AudioDecodingServiceProtocol: AnyObject {
    func decodePCMFloatSamples(from fileURL: URL) async throws -> [Float]
}

enum AudioDecodingServiceError: LocalizedError {
    case emptyAudio
    case unsupportedOutputFormat
    case conversionFailed
    case missingChannelData

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "The recorded audio file did not contain any samples."
        case .unsupportedOutputFormat:
            return "DictaFlow could not prepare the audio for Whisper transcription."
        case .conversionFailed:
            return "DictaFlow could not convert the recording into Whisper's PCM format."
        case .missingChannelData:
            return "DictaFlow could not read the converted audio samples."
        }
    }
}

actor AVAudioDecodingService: AudioDecodingServiceProtocol {
    nonisolated private static let targetSampleRate: Double = 16_000

    nonisolated init() {}

    func decodePCMFloatSamples(from fileURL: URL) async throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let inputFormat = audioFile.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioDecodingServiceError.unsupportedOutputFormat
        }

        let inputFrameCount = AVAudioFrameCount(audioFile.length)
        guard inputFrameCount > 0 else {
            throw AudioDecodingServiceError.emptyAudio
        }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            throw AudioDecodingServiceError.conversionFailed
        }

        try audioFile.read(into: inputBuffer)

        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate) + 1_024
        )

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            throw AudioDecodingServiceError.conversionFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioDecodingServiceError.conversionFailed
        }

        var didProvideInput = false
        var conversionError: NSError?

        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if didProvideInput {
                outputStatus.pointee = .endOfStream
                return nil
            }

            didProvideInput = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw conversionError
        }

        guard status == .haveData || status == .endOfStream else {
            throw AudioDecodingServiceError.conversionFailed
        }

        guard let channelData = outputBuffer.floatChannelData?.pointee else {
            throw AudioDecodingServiceError.missingChannelData
        }

        let sampleCount = Int(outputBuffer.frameLength)
        guard sampleCount > 0 else {
            throw AudioDecodingServiceError.emptyAudio
        }

        return Array(UnsafeBufferPointer(start: channelData, count: sampleCount))
    }
}
