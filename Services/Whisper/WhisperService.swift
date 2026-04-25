import Foundation
import OSLog
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
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DictaFlow",
        category: "Whisper"
    )
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
        logDecodedAudioStats(samples)
        let context = try context(for: modelURL)
        let languageCode = configuration.inputLanguage.whisperCode ?? "auto"

        return try languageCode.withCString { languagePointer in
            try runTranscription(
                context: context,
                samples: samples,
                configuration: configuration,
                languagePointer: languagePointer
            )
        }
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
        // In whisper.cpp, detect_language exits after language detection. Use "auto" to detect and transcribe.
        parameters.detect_language = false
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

        let transcriptText = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

        // Diagnostic log: this records local dictation text and requires care in shared logs.
        logger.info(
            "Whisper inference completed: segments=\(segmentCount, privacy: .public), detectedLanguage=\(languageCode ?? "unknown", privacy: .public), transcript=\"\(transcriptText, privacy: .public)\""
        )

        return WhisperTranscriptionResult(
            text: transcriptText,
            segments: segments,
            detectedLanguageCode: languageCode,
            model: configuration.model,
            taskMode: configuration.taskMode,
            completedAt: Date()
        )
    }

    private func logDecodedAudioStats(_ samples: [Float]) {
        guard !samples.isEmpty else {
            logger.info("Whisper decoded audio: samples=0, duration=0.000s, rms=0.000000, peak=0.000000, activeSamples=0")
            return
        }

        var sumOfSquares: Double = 0
        var peak: Float = 0
        var activeSampleCount = 0

        for sample in samples {
            let absoluteSample = abs(sample)
            peak = max(peak, absoluteSample)
            sumOfSquares += Double(sample * sample)

            if absoluteSample >= Self.activityThreshold {
                activeSampleCount += 1
            }
        }

        let rms = sqrt(sumOfSquares / Double(samples.count))
        let duration = Double(samples.count) / Self.decodedSampleRate

        logger.info(
            "Whisper decoded audio: samples=\(samples.count, privacy: .public), duration=\(duration, format: .fixed(precision: 3), privacy: .public)s, rms=\(rms, format: .fixed(precision: 6), privacy: .public), peak=\(Double(peak), format: .fixed(precision: 6), privacy: .public), activeSamples=\(activeSampleCount, privacy: .public)"
        )
    }

    private static let decodedSampleRate: Double = 16_000
    private static let activityThreshold: Float = 0.001

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
