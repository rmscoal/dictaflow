import Foundation

protocol TranscriptRefinementServiceProtocol: AnyObject {
    func refine(
        transcript: String,
        whisperTaskMode: WhisperTaskMode,
        modelURL: URL,
        configuration: RefinementConfiguration
    ) async throws -> TranscriptRefinementResult
}

enum TranscriptRefinementServiceError: LocalizedError {
    case missingRuntime
    case failedToRun(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .missingRuntime:
            return "DictaFlow could not find a local llama.cpp runtime for transcript refinement."
        case .failedToRun(let details):
            return "The local refinement model could not clean the transcript. \(details)"
        case .emptyOutput:
            return "The local refinement model returned an empty result."
        }
    }
}

actor LlamaCLITranscriptRefinementService: TranscriptRefinementServiceProtocol {
    private let executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    func refine(
        transcript: String,
        whisperTaskMode: WhisperTaskMode,
        modelURL: URL,
        configuration: RefinementConfiguration
    ) async throws -> TranscriptRefinementResult {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw TranscriptRefinementServiceError.emptyOutput
        }

        let runtimeURL = try resolveRuntimeURL()
        let prompt = Self.makePrompt(transcript: trimmedTranscript, whisperTaskMode: whisperTaskMode)
        let maxTokens = Self.maxPredictionTokens(for: trimmedTranscript)
        let output = try await runLlamaCLI(
            runtimeURL: runtimeURL,
            modelURL: modelURL,
            prompt: prompt,
            maxTokens: maxTokens
        )
        let refinedText = Self.cleanedModelOutput(output)

        guard !refinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptRefinementServiceError.emptyOutput
        }

        return TranscriptRefinementResult(
            originalText: transcript,
            refinedText: refinedText,
            model: configuration.model,
            mode: configuration.mode,
            completedAt: Date()
        )
    }

    private func resolveRuntimeURL() throws -> URL {
        if let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) {
            return executableURL
        }

        if let bundledURL = Bundle.main.url(forAuxiliaryExecutable: "llama-cli"),
           FileManager.default.isExecutableFile(atPath: bundledURL.path) {
            return bundledURL
        }

        if let bundledResourceURL = Bundle.main.url(forResource: "llama-cli", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundledResourceURL.path) {
            return bundledResourceURL
        }

        let developmentPaths = [
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli"
        ]

        if let path = developmentPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        throw TranscriptRefinementServiceError.missingRuntime
    }

    private func runLlamaCLI(
        runtimeURL: URL,
        modelURL: URL,
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = runtimeURL
            process.arguments = [
                "-m", modelURL.path,
                "-p", prompt,
                "-n", "\(maxTokens)",
                "--temp", "0.15",
                "--top-p", "0.9",
                "--no-display-prompt"
            ]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw TranscriptRefinementServiceError.failedToRun(error.localizedDescription)
            }

            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw TranscriptRefinementServiceError.failedToRun(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            return output
        }.value
    }

    nonisolated private static func makePrompt(transcript: String, whisperTaskMode: WhisperTaskMode) -> String {
        """
        <|im_start|>system
        You clean dictated transcripts. Preserve meaning. Do not add facts, answer questions, or explain. Fix punctuation, grammar, casing, spacing, repeated words, and harmless filler. Use paragraphs, bullets, or numbered lists only when clearly implied. Preserve tone and language. Output only the cleaned text.<|im_end|>
        <|im_start|>user
        Task: Smart cleanup
        Whisper mode: \(whisperTaskMode.rawValue)
        Transcript:
        \(transcript)<|im_end|>
        <|im_start|>assistant
        """
    }

    nonisolated private static func maxPredictionTokens(for transcript: String) -> Int {
        min(1024, max(128, transcript.count / 3))
    }

    nonisolated private static func cleanedModelOutput(_ output: String) -> String {
        var cleanedOutput = output
        let wrappers = [
            "<|im_end|>",
            "<|endoftext|>",
            "<|im_start|>assistant",
            "<|im_start|>"
        ]

        for wrapper in wrappers {
            cleanedOutput = cleanedOutput.replacingOccurrences(of: wrapper, with: "")
        }

        return cleanedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
