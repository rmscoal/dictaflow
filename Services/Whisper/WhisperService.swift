import CryptoKit
import Foundation
import OSLog
import whisper

protocol WhisperServiceProtocol: AnyObject {
    func transcribe(
        audioFileURL: URL,
        modelURL: URL,
        configuration: WhisperConfiguration
    ) async throws -> WhisperTranscriptionResult
    func warmUpEncoder(
        audioFileURL: URL,
        modelURL: URL,
        configuration: WhisperConfiguration
    ) async throws
    func prepare(modelURL: URL) async throws
    func unloadModel() async
}

enum WhisperServiceError: LocalizedError, Equatable {
    case failedToInitializeContext
    case transcriptionFailed
    case missingVADModel
    case invalidVADModel
    case speechDetectionFailed

    var errorDescription: String? {
        switch self {
        case .failedToInitializeContext:
            return "DictaFlow could not initialize Whisper with the selected local model."
        case .transcriptionFailed:
            return "Whisper could not transcribe the recorded audio."
        case .missingVADModel:
            return "The bundled speech detection model is missing. Reinstall DictaFlow and try again."
        case .invalidVADModel:
            return "The bundled speech detection model could not be verified. Reinstall DictaFlow and try again."
        case .speechDetectionFailed:
            return "Speech detection could not process the recording. Restart DictaFlow and try again."
        }
    }
}

actor WhisperCPPService: WhisperServiceProtocol {
    nonisolated static let vadModelName = "ggml-silero-v6.2.0"
    nonisolated static let vadModelSHA256 = "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DictaFlow",
        category: "Whisper"
    )
    private let audioDecodingService: AudioDecodingServiceProtocol
    private let vadModelURL: URL?
    private var hasVerifiedVADModel = false
    private var cachedContext: (modelURL: URL, context: WhisperContextBox)?

    nonisolated init(
        audioDecodingService: AudioDecodingServiceProtocol = AVAudioDecodingService(),
        vadModelURL: URL? = Bundle.main.url(forResource: WhisperCPPService.vadModelName, withExtension: "bin")
    ) {
        self.audioDecodingService = audioDecodingService
        self.vadModelURL = vadModelURL
    }

    func transcribe(
        audioFileURL: URL,
        modelURL: URL,
        configuration: WhisperConfiguration
    ) async throws -> WhisperTranscriptionResult {
        let vadModelURL = try verifiedVADModelURL()
        return try await decodeAndTranscribe(
            audioFileURL: audioFileURL,
            modelURL: modelURL,
            configuration: configuration,
            vadModelURL: vadModelURL
        )
    }

    // Silent audio must reach Whisper to compile the Neural Engine encoder.
    // Only this dedicated warmup path bypasses speech detection.
    func warmUpEncoder(
        audioFileURL: URL,
        modelURL: URL,
        configuration: WhisperConfiguration
    ) async throws {
        _ = try await decodeAndTranscribe(
            audioFileURL: audioFileURL,
            modelURL: modelURL,
            configuration: configuration,
            vadModelURL: nil
        )
    }

    private func decodeAndTranscribe(
        audioFileURL: URL,
        modelURL: URL,
        configuration: WhisperConfiguration,
        vadModelURL: URL?
    ) async throws -> WhisperTranscriptionResult {
        let samples = try await audioDecodingService.decodePCMFloatSamples(from: audioFileURL)
        logDecodedAudioStats(samples)
        let context = try context(for: modelURL)
        let languageCode = configuration.inputLanguage.whisperCode ?? "auto"
        let initialPrompt = configuration.initialPrompt
        let vadModelPath = vadModelURL?.path

        return try languageCode.withCString { languagePointer in
            try (initialPrompt ?? "").withCString { promptPointer in
                try (vadModelPath ?? "").withCString { vadModelPointer in
                    try runTranscription(
                        context: context,
                        samples: samples,
                        configuration: configuration,
                        languagePointer: languagePointer,
                        promptPointer: initialPrompt == nil ? nil : promptPointer,
                        vadModelPointer: vadModelPath == nil ? nil : vadModelPointer
                    )
                }
            }
        }
    }

    func prepare(modelURL: URL) async throws {
        _ = try verifiedVADModelURL()
        _ = try context(for: modelURL)
    }

    func verifiedVADModelURL() throws -> URL {
        guard let vadModelURL, FileManager.default.fileExists(atPath: vadModelURL.path) else {
            throw WhisperServiceError.missingVADModel
        }
        guard !hasVerifiedVADModel else { return vadModelURL }

        guard let data = try? Data(contentsOf: vadModelURL),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.vadModelSHA256 else {
            throw WhisperServiceError.invalidVADModel
        }
        hasVerifiedVADModel = true
        return vadModelURL
    }

    func unloadModel() {
        guard let cachedContext else {
            return
        }

        logger.info("Whisper model unloaded after idle: \(cachedContext.modelURL.lastPathComponent, privacy: .public)")
        self.cachedContext = nil
    }

    private func context(for modelURL: URL) throws -> WhisperContextBox {
        if let cachedContext, cachedContext.modelURL == modelURL {
            return cachedContext.context
        }

        cachedContext = nil

        var contextParameters = whisper_context_default_params()
        contextParameters.flash_attn = true
        let contextPointer = whisper_init_from_file_with_params(modelURL.path, contextParameters)

        guard let contextPointer else {
            throw WhisperServiceError.failedToInitializeContext
        }

        logger.info("Whisper model loaded: \(modelURL.lastPathComponent, privacy: .public)")
        let context = WhisperContextBox(pointer: contextPointer)
        cachedContext = (modelURL, context)
        return context
    }

    private func runTranscription(
        context: WhisperContextBox,
        samples: [Float],
        configuration: WhisperConfiguration,
        languagePointer: UnsafePointer<CChar>?,
        promptPointer: UnsafePointer<CChar>?,
        vadModelPointer: UnsafePointer<CChar>?
    ) throws -> WhisperTranscriptionResult {
        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_realtime = false
        parameters.print_progress = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.translate = configuration.taskMode == .translateToEnglish
        parameters.language = languagePointer
        parameters.initial_prompt = promptPointer
        // In whisper.cpp, detect_language exits after language detection. Use "auto" to detect and transcribe.
        parameters.detect_language = false
        parameters.n_threads = Int32(Self.recommendedThreadCount)
        parameters.offset_ms = 0
        parameters.duration_ms = 0
        parameters.no_context = true
        parameters.no_timestamps = false
        parameters.single_segment = false
        parameters.vad = vadModelPointer != nil
        parameters.vad_model_path = vadModelPointer
        // The vendored 250 ms minimum drops brief words such as "No" and "Look".
        // Keep the other VAD defaults, including speech padding and overlap.
        parameters.vad_params.min_speech_duration_ms = 100

        whisper_reset_timings(context.pointer)

        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_full(context.pointer, parameters, buffer.baseAddress, Int32(buffer.count))
        }

        guard status == 0 else {
            if parameters.vad, status == -1 {
                throw WhisperServiceError.speechDetectionFailed
            }
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
        if segmentCount > 0, detectedLanguageIdentifier >= 0, let detectedLanguageCString = whisper_lang_str(detectedLanguageIdentifier) {
            languageCode = String(cString: detectedLanguageCString)
        } else {
            languageCode = nil
        }

        let transcriptText = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info(
            "Whisper inference completed: segments=\(segmentCount, privacy: .public), detectedLanguage=\(languageCode ?? "unknown", privacy: .public), transcriptCharacters=\(transcriptText.count, privacy: .public)"
        )

        return WhisperTranscriptionResult(
            text: transcriptText,
            segments: transcriptText.isEmpty ? [] : segments,
            detectedLanguageCode: transcriptText.isEmpty ? nil : languageCode,
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
