import Darwin
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
    case timedOut
    case emptyOutput
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .missingRuntime:
            return "DictaFlow could not find a local llama.cpp runtime for transcript refinement."
        case .failedToRun(let details):
            return "The local refinement model could not clean the transcript. \(details)"
        case .timedOut:
            return "The local refinement model took too long to respond."
        case .emptyOutput:
            return "The local refinement model returned an empty result."
        case .outputTooLarge:
            return "The local refinement model produced more output than DictaFlow can safely process."
        }
    }
}

actor LlamaCLITranscriptRefinementService: TranscriptRefinementServiceProtocol {
    nonisolated private static let outputCaptureLimitBytes = 1_000_000
    nonisolated private static let errorCaptureLimitBytes = 256_000
    nonisolated private static let promptDirectoryName = "DictaFlowRefinementPrompts"

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

        #if DEBUG
            let developmentPaths = [
                "/opt/homebrew/bin/llama-cli",
                "/usr/local/bin/llama-cli"
            ]

            if let path = developmentPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return URL(fileURLWithPath: path)
            }
        #endif

        throw TranscriptRefinementServiceError.missingRuntime
    }

    private func runLlamaCLI(
        runtimeURL: URL,
        modelURL: URL,
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let promptFileURL = try Self.writePromptToTemporaryFile(prompt)
            defer {
                try? FileManager.default.removeItem(at: promptFileURL)
            }

            let process = Process()
            process.executableURL = runtimeURL
            process.arguments = [
                "-m", modelURL.path,
                "--file", promptFileURL.path,
                "-n", "\(maxTokens)",
                "--temp", "0.0",
                "--top-p", "0.9",
                "--no-display-prompt"
            ]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let outputCapture = LimitedPipeCapture(limit: Self.outputCaptureLimitBytes)
            let errorCapture = LimitedPipeCapture(limit: Self.errorCaptureLimitBytes)

            do {
                try process.run()
            } catch {
                throw TranscriptRefinementServiceError.failedToRun(error.localizedDescription)
            }

            let outputTask = Task.detached(priority: .utility) {
                outputCapture.read(from: outputPipe.fileHandleForReading)
            }
            let errorTask = Task.detached(priority: .utility) {
                errorCapture.read(from: errorPipe.fileHandleForReading)
            }

            let didExit = await Self.waitForExit(process, timeoutNanoseconds: 60_000_000_000)
            guard didExit else {
                process.terminate()
                let didTerminate = await Self.waitForExit(process, timeoutNanoseconds: 2_000_000_000)
                if !didTerminate, process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = await Self.waitForExit(process, timeoutNanoseconds: 1_000_000_000)
                }
                Self.closePipeReaders(outputPipe, errorPipe)
                await outputTask.value
                await errorTask.value
                throw TranscriptRefinementServiceError.timedOut
            }

            await outputTask.value
            await errorTask.value

            let outputData = try outputCapture.capturedData()
            _ = try errorCapture.capturedData()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw TranscriptRefinementServiceError.failedToRun("Exit status \(process.terminationStatus).")
            }

            return output
        }.value
    }

    nonisolated private static func writePromptToTemporaryFile(_ prompt: String) throws -> URL {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(promptDirectoryName, isDirectory: true)
        try ensurePrivateTemporaryDirectory(at: directoryURL, using: fileManager)

        let fileURL = directoryURL
            .appendingPathComponent("prompt-\(UUID().uuidString.lowercased()).txt", isDirectory: false)
        guard let promptData = prompt.data(using: .utf8),
              fileManager.createFile(
                atPath: fileURL.path,
                contents: promptData,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
              ) else {
            throw TranscriptRefinementServiceError.failedToRun("Could not create a secure local prompt file.")
        }

        var excludedURL = fileURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try excludedURL.setResourceValues(resourceValues)
        return fileURL
    }

    nonisolated private static func ensurePrivateTemporaryDirectory(at directoryURL: URL, using fileManager: FileManager) throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )

            let resourceValues = try directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard resourceValues.isDirectory == true, resourceValues.isSymbolicLink != true else {
                throw TranscriptRefinementServiceError.failedToRun("The local prompt folder is not a private directory.")
            }

            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directoryURL.path
            )
        } catch let error as TranscriptRefinementServiceError {
            throw error
        } catch {
            throw TranscriptRefinementServiceError.failedToRun("Could not create a secure local prompt folder.")
        }
    }

    nonisolated private static func closePipeReaders(_ pipes: Pipe...) {
        for pipe in pipes {
            try? pipe.fileHandleForReading.close()
        }
    }

    nonisolated private static func waitForExit(_ process: Process, timeoutNanoseconds: UInt64) async -> Bool {
        await ProcessExitWaiter().wait(for: process, timeoutNanoseconds: timeoutNanoseconds)
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

private final class LimitedPipeCapture: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    nonisolated(unsafe) private var data = Data()
    nonisolated(unsafe) private var didExceedLimit = false

    nonisolated init(limit: Int) {
        self.limit = limit
    }

    nonisolated func read(from fileHandle: FileHandle) {
        while true {
            let chunk = fileHandle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty {
                break
            }

            append(chunk)
        }
    }

    nonisolated func capturedData() throws -> Data {
        lock.lock()
        defer {
            lock.unlock()
        }

        if didExceedLimit {
            throw TranscriptRefinementServiceError.outputTooLarge
        }

        return data
    }

    nonisolated private func append(_ chunk: Data) {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard !didExceedLimit else {
            return
        }

        if data.count + chunk.count <= limit {
            data.append(chunk)
            return
        }

        let remainingByteCount = max(0, limit - data.count)
        if remainingByteCount > 0 {
            data.append(chunk.prefix(remainingByteCount))
        }
        didExceedLimit = true
    }
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var didResume = false
    nonisolated(unsafe) private var continuation: CheckedContinuation<Bool, Never>?

    nonisolated func wait(for process: Process, timeoutNanoseconds: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            process.terminationHandler = { [waiter = self] process in
                process.terminationHandler = nil
                Task { @MainActor in
                    waiter.resume(returning: true)
                }
            }

            guard process.isRunning else {
                process.terminationHandler = nil
                resume(returning: true)
                return
            }

            Task { [waiter = self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                process.terminationHandler = nil
                waiter.resume(returning: false)
            }
        }
    }

    nonisolated private func resume(returning result: Bool) {
        let continuationToResume: CheckedContinuation<Bool, Never>?

        lock.lock()
        if didResume {
            lock.unlock()
            return
        }

        didResume = true
        continuationToResume = continuation
        continuation = nil
        lock.unlock()

        continuationToResume?.resume(returning: result)
    }
}
