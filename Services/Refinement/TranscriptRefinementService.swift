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
                "--temp", "0.0",
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
        You clean dictated transcripts for insertion into another app.

        Rules:
        - Preserve the speaker's meaning and intent. Do not add facts, answer questions, or explain.
        - If Whisper mode is transcribe, preserve the spoken language. If Whisper mode is translateToEnglish, output English.
        - Be aggressive about cleanup when the transcript contains dictated speech artifacts.
        - Remove filler words and discourse markers that do not add meaning, including "um", "uh", "like", "you know", "basically", "kind of", "sort of", "well", and "so". Keep "like" only when it means enjoy or similar to.
        - Remove hesitation, repeated words, duplicated phrases, false starts, and repeated ideas.
        - If two nearby words, phrases, or clauses express the same meaning, keep only the clearest version.
        - If a word or phrase can be deleted without changing the intended meaning, delete it.
        - Resolve explicit self-corrections. When the speaker revises with words like "sorry", "actually", "I mean", "no", "scratch that", or "never mind", keep the corrected later wording and remove the abandoned wording.
        - When the output language is English, edit like a strict but natural copy editor: improve grammar, sentence structure, word choice, and clarity.
        - Rephrase awkward dictated wording into fluent written English when the intended meaning is clear.
        - Prefer concise, natural phrasing. Smooth awkward dictation without changing tone or rewriting into a different style.
        - Keep the speaker's tone: casual text should stay casual, and professional text should stay professional.
        - Do not over-polish, add emphasis, or make the text sound more formal than intended.
        - Fix punctuation, grammar, casing, and spacing.
        - Preserve names, numbers, dates, times, URLs, code, commands, and formatting-sensitive text unless the transcript clearly corrects them.
        - Use paragraphs, bullets, or numbered lists only when clearly implied.
        - Output only the cleaned text.

        Examples:
        Raw: let's meet at 5 a.m. never mind sorry let's meet at 6 a.m.
        Cleaned: Let's meet at 6 a.m.

        Raw: I I think we should ship this tomorrow actually no ship it Friday
        Cleaned: I think we should ship this Friday.

        Raw: I was wondering maybe we can trying to finish this today
        Cleaned: I was wondering if we could try to finish this today.

        Raw: I want to like meet tomorrow like at noon
        Cleaned: I want to meet tomorrow at noon.

        Raw: I'm still seeing like duplicates like the same meaning and duplicates in the result
        Cleaned: I'm still seeing duplicate wording and repeated meaning in the result.

        Raw: We need more time because we need more time to prepare for the launch
        Cleaned: We need more time to prepare for the launch.<|im_end|>
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
