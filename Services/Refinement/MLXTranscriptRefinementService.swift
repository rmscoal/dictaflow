import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
import OSLog

/// Experimental native backend. All weights and tokenizer files are verified before loading.
actor MLXTranscriptRefinementService {
    private let idleSleepSeconds: Int
    private var container: ModelContainer?
    private var directoryURL: URL?
    private var loadTask: Task<ModelContainer, Error>?
    private var generationTask: Task<TranscriptRefinementResult, Error>?
    private var shutdownTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var sessionID = UUID()
    private let logger = Logger(subsystem: "DictaFlow", category: "Refinement")

    init(idleSleepSeconds: Int = 300) { self.idleSleepSeconds = idleSleepSeconds }

    func prepare(modelURL: URL) async throws {
        await shutdownTask?.value
        try Task.checkCancellation()
        idleTask?.cancel()
        if container != nil, directoryURL == modelURL { scheduleIdleSleep(); return }
        let id = sessionID
        let task: Task<ModelContainer, Error>
        if let loading = loadTask {
            task = loading
        } else {
            task = Task {
                try await LLMModelFactory.shared.loadContainer(from: modelURL, using: #huggingFaceTokenizerLoader())
            }
            loadTask = task
        }
        do {
            let loaded = try await task.value
            try Task.checkCancellation()
            guard sessionID == id else { throw CancellationError() }
            container = loaded
            directoryURL = modelURL
            loadTask = nil
            scheduleIdleSleep()
        } catch {
            if sessionID == id { loadTask = nil }
            throw error
        }
    }

    func stop() async {
        if let shutdownTask { await shutdownTask.value; return }
        // Do not initialize MLX's GPU allocator just to stop an unused backend.
        guard container != nil || loadTask != nil || generationTask != nil || idleTask != nil else { return }
        sessionID = UUID()
        idleTask?.cancel()
        idleTask = nil
        loadTask?.cancel()
        generationTask?.cancel()
        let task = Task { [loading = loadTask, generation = generationTask] in
            _ = try? await loading?.value
            _ = try? await generation?.value
        }
        loadTask = nil
        generationTask = nil
        container = nil
        directoryURL = nil
        shutdownTask = task
        await task.value
        shutdownTask = nil
        Memory.clearCache()
    }

    func refine(transcript: String, whisperTaskMode: WhisperTaskMode, modelURL: URL,
                configuration: RefinementConfiguration, promptTemplate: String) async throws -> TranscriptRefinementResult {
        try await prepare(modelURL: modelURL)
        guard let container else { throw TranscriptRefinementServiceError.missingRuntime }
        idleTask?.cancel()
        let id = sessionID
        let task = Task {
            try await self.generate(container: container, transcript: transcript,
                whisperTaskMode: whisperTaskMode, configuration: configuration, promptTemplate: promptTemplate)
        }
        generationTask = task
        defer {
            if sessionID == id {
                generationTask = nil
                scheduleIdleSleep()
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func generate(container: ModelContainer, transcript: String, whisperTaskMode: WhisperTaskMode,
                          configuration: RefinementConfiguration, promptTemplate: String) async throws -> TranscriptRefinementResult {
        let input = try await container.prepare(input: UserInput(messages: [
            ["role": "system", "content": RefinementPromptTemplate.renderedInstructions(from: promptTemplate, whisperTaskMode: whisperTaskMode)],
            ["role": "user", "content": transcript]
        ], additionalContext: ["enable_thinking": false]))
        let maximumTokens = RefinementInference.maximumOutputTokens(for: transcript)
        guard input.text.tokens.size + maximumTokens <= 4096 else { throw TranscriptRefinementServiceError.incompleteOutput }
        let stream = try await container.generate(input: input,
            parameters: GenerateParameters(maxTokens: maximumTokens, temperature: 0.2, topP: 0.9))
        var output = ""
        var finished = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        for await event in stream {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw TranscriptRefinementServiceError.timedOut }
            switch event {
            case .chunk(let text): output += text
            case .info(let info):
                finished = info.stopReason == .stop
                logger.info("mlx refinement promptSeconds=\(info.promptTime) generationSeconds=\(info.generateTime) outputTokens=\(info.generationTokenCount)")
            case .toolCall: throw TranscriptRefinementServiceError.incompleteOutput
            }
        }
        guard finished else { throw TranscriptRefinementServiceError.incompleteOutput }
        return try RefinementInference.result(output, original: transcript, configuration: configuration)
    }

    private func scheduleIdleSleep() {
        idleTask?.cancel()
        let seconds = idleSleepSeconds
        idleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
                await self?.stop()
            } catch {}
        }
    }
}
