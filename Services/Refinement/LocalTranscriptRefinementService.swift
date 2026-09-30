import Foundation

/// Keeps the app's pipeline independent of the experimental inference backend.
actor LocalTranscriptRefinementService: TranscriptRefinementServiceProtocol {
    private let llama = LlamaCLITranscriptRefinementService()
    private let mlx = MLXTranscriptRefinementService()

    func isRuntimeAvailable(for model: RefinementModelDescriptor) async -> Bool {
        if model.usesMLX {
            #if arch(arm64)
            return true
            #else
            return false
            #endif
        }
        return await llama.isRuntimeAvailable(for: model)
    }

    func prepare(modelURL: URL) async throws {
        if modelURL.pathExtension == "gguf" {
            await mlx.stop()
            try await llama.prepare(modelURL: modelURL)
        } else {
            await llama.stop()
            try await mlx.prepare(modelURL: modelURL)
        }
    }

    func reloadModels() async {}

    func stop() async {
        await llama.stop()
        await mlx.stop()
    }

    func refine(transcript: String, whisperTaskMode: WhisperTaskMode, modelURL: URL,
                configuration: RefinementConfiguration, promptTemplate: String) async throws -> TranscriptRefinementResult {
        if configuration.model.usesMLX {
            return try await mlx.refine(transcript: transcript, whisperTaskMode: whisperTaskMode,
                modelURL: modelURL, configuration: configuration, promptTemplate: promptTemplate)
        }
        return try await llama.refine(transcript: transcript, whisperTaskMode: whisperTaskMode,
            modelURL: modelURL, configuration: configuration, promptTemplate: promptTemplate)
    }
}

