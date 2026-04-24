import Foundation
import whisper

protocol WhisperServiceProtocol: AnyObject {
    func transcribe(
        audioFileURL: URL,
        modelURL: URL,
        configuration: WhisperConfiguration
    ) async throws -> WhisperTranscriptionResult
}

enum WhisperServiceError: LocalizedError {
    case failedToInitializeContext
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .failedToInitializeContext:
            return "DictaFlow could not initialize Whisper with the selected local model."
        case .transcriptionFailed:
            return "Whisper could not transcribe the recorded audio."
        }
    }
}

actor WhisperCPPService: WhisperServiceProtocol {
    private let audioDecodingService: AudioDecodingServiceProtocol
    private var cachedContexts: [URL: WhisperContextBox] = [:]

    nonisolated init(audioDecodingService: AudioDecodingServiceProtocol = AVAudioDecodingService()) {
        self.audioDecodingService = audioDecodingService
    }

    func transcribe(
        audioFileURL: URL,
        modelURL: URL,
        configuration: WhisperConfiguration
    ) async throws -> WhisperTranscriptionResult {
        let samples = try await audioDecodingService.decodePCMFloatSamples(from: audioFileURL)
        let context = try context(for: modelURL)

        if let languageCode = configuration.inputLanguage.whisperCode {
            return try languageCode.withCString { languagePointer in
                try runTranscription(
                    context: context,
                    samples: samples,
                    configuration: configuration,
                    languagePointer: languagePointer
                )
            }
        }

        return try runTranscription(
            context: context,
            samples: samples,
            configuration: configuration,
            languagePointer: nil
        )
    }

    private func context(for modelURL: URL) throws -> WhisperContextBox {
        if let existingContext = cachedContexts[modelURL] {
            return existingContext
        }

        var contextParameters = whisper_context_default_params()
        contextParameters.flash_attn = true
        let contextPointer = whisper_init_from_file_with_params(modelURL.path, contextParameters)

        guard let contextPointer else {
            throw WhisperServiceError.failedToInitializeContext
        }

        let context = WhisperContextBox(pointer: contextPointer)
        cachedContexts[modelURL] = context
        return context
    }

    private func runTranscription(
        context: WhisperContextBox,
        samples: [Float],
        configuration: WhisperConfiguration,
        languagePointer: UnsafePointer<CChar>?
    ) throws -> WhisperTranscriptionResult {
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_realtime = false
        parameters.print_progress = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.translate = configuration.taskMode == .translateToEnglish
        parameters.language = languagePointer
        parameters.detect_language = configuration.inputLanguage == .automatic
        parameters.n_threads = Int32(Self.recommendedThreadCount)
        parameters.offset_ms = 0
        parameters.duration_ms = 0
        parameters.no_context = true
        parameters.no_timestamps = false
        parameters.single_segment = false

        whisper_reset_timings(context.pointer)

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context.pointer, parameters, buffer.baseAddress, Int32(buffer.count))
        }

        guard status == 0 else {
            throw WhisperServiceError.transcriptionFailed
        }

        let segmentCount = Int(whisper_full_n_segments(context.pointer))
        let segments = (0..<segmentCount).map { index in
            let text = String(cString: whisper_full_get_segment_text(context.pointer, Int32(index)))
            let start = TimeInterval(whisper_full_get_segment_t0(context.pointer, Int32(index))) * 0.01
            let end = TimeInterval(whisper_full_get_segment_t1(context.pointer, Int32(index))) * 0.01
            return WhisperTranscriptionSegment(text: text, startTime: start, endTime: end)
        }

        let languageCode: String?
        let detectedLanguageIdentifier = whisper_full_lang_id(context.pointer)
        if detectedLanguageIdentifier >= 0, let detectedLanguageCString = whisper_lang_str(detectedLanguageIdentifier) {
            languageCode = String(cString: detectedLanguageCString)
        } else {
            languageCode = nil
        }

        return WhisperTranscriptionResult(
            text: segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments,
            detectedLanguageCode: languageCode,
            model: configuration.model,
            taskMode: configuration.taskMode,
            completedAt: Date()
        )
    }

    private static var recommendedThreadCount: Int {
        max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
    }
}

private final class WhisperContextBox {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        whisper_free(pointer)
    }
}
