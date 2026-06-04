import Darwin
import Foundation

protocol TranscriptRefinementServiceProtocol: AnyObject {
    func isRuntimeAvailable() async -> Bool
    func prepare(modelURL: URL) async throws
    func stop() async

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
    private let urlSession: URLSession
    private var serverProcess: Process?
    private var serverModelURL: URL?
    private var serverBaseURL: URL?

    init(executableURL: URL? = nil, urlSession: URLSession = .shared) {
        self.executableURL = executableURL
        self.urlSession = urlSession
    }

    func isRuntimeAvailable() async -> Bool {
        do {
            _ = try resolveRuntimeURL()
            return true
        } catch {
            return false
        }
    }

    func stop() async {
        stopServer()
    }

    func prepare(modelURL: URL) async throws {
        _ = try await ensureServer(for: modelURL)
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

        let prompt = Self.makePrompt(
            transcript: trimmedTranscript,
            whisperTaskMode: whisperTaskMode,
            configuration: configuration
        )
        let maxTokens = Self.maxPredictionTokens(for: trimmedTranscript)
        let output = try await runPromptOnServer(
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

        if let bundledURL = Bundle.main.url(forAuxiliaryExecutable: "llama-server"),
            FileManager.default.isExecutableFile(atPath: bundledURL.path) {
            return bundledURL
        }

        if let bundledResourceURL = Bundle.main.url(forResource: "llama-server", withExtension: nil),
            FileManager.default.isExecutableFile(atPath: bundledResourceURL.path) {
            return bundledResourceURL
        }

        #if DEBUG
            let developmentPaths = [
                "/opt/homebrew/bin/llama-server",
                "/usr/local/bin/llama-server"
            ]

            if let path = developmentPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return URL(fileURLWithPath: path)
            }
        #endif

        throw TranscriptRefinementServiceError.missingRuntime
    }

    private func runPromptOnServer(
        modelURL: URL,
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        let baseURL = try await ensureServer(for: modelURL)
        let requestURL = baseURL.appendingPathComponent("completion")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let payload: [String: Any] = [
            "prompt": prompt,
            "n_predict": maxTokens,
            "temperature": 0.2,
            "top_p": 0.9,
            "stream": false,
            "cache_prompt": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptRefinementServiceError.failedToRun("The local llama-server returned an invalid response.")
        }

        guard httpResponse.statusCode == 200 else {
            let responseText = String(data: data, encoding: .utf8) ?? "HTTP status \(httpResponse.statusCode)."
            throw TranscriptRefinementServiceError.failedToRun(responseText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptRefinementServiceError.failedToRun("The local llama-server returned invalid JSON.")
        }

        if let content = json["content"] as? String {
            return content
        }

        if let choices = json["choices"] as? [[String: Any]],
           let text = choices.first?["text"] as? String {
            return text
        }

        throw TranscriptRefinementServiceError.emptyOutput
    }

    private func ensureServer(for modelURL: URL) async throws -> URL {
        if let serverProcess,
           serverProcess.isRunning,
           serverModelURL == modelURL,
           let serverBaseURL {
            return serverBaseURL
        }

        stopServer()

        let runtimeURL = try resolveRuntimeURL()
        let port = try Self.availableLocalPort()
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let process = Process()
        process.executableURL = runtimeURL
        process.arguments = [
            "--model", modelURL.path,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--n-gpu-layers", "all",
            "--flash-attn", "auto",
            "--threads", "\(Self.optimalThreadCount())",
            "--threads-batch", "\(Self.optimalThreadCount())",
            "--ctx-size", "2048",
            "--batch-size", "512",
            "--parallel", "1",
            "--no-ui",
            "--no-webui",
            "--log-disable"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw TranscriptRefinementServiceError.failedToRun(error.localizedDescription)
        }

        serverProcess = process
        serverModelURL = modelURL
        serverBaseURL = baseURL

        try await waitForServerReady(baseURL: baseURL, process: process)
        return baseURL
    }

    private func waitForServerReady(baseURL: URL, process: Process) async throws {
        let healthURL = baseURL.appendingPathComponent("health")
        let deadline = Date().addingTimeInterval(120)

        while Date() < deadline {
            if !process.isRunning {
                throw TranscriptRefinementServiceError.failedToRun("The local llama-server exited before it was ready.")
            }

            do {
                let (_, response) = try await urlSession.data(from: healthURL)
                if let httpResponse = response as? HTTPURLResponse,
                   (200..<300).contains(httpResponse.statusCode) {
                    return
                }
            } catch {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        throw TranscriptRefinementServiceError.timedOut
    }

    private func stopServer() {
        guard let serverProcess else {
            return
        }

        if serverProcess.isRunning {
            serverProcess.terminate()
        }

        self.serverProcess = nil
        self.serverModelURL = nil
        self.serverBaseURL = nil
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
                "--n-gpu-layers", "all",
                "--flash-attn", "auto",
                "--threads", "\(Self.optimalThreadCount())",
                "--threads-batch", "\(Self.optimalThreadCount())",
                "--ctx-size", "2048",
                "--batch-size", "512",
                "-n", "\(maxTokens)",
                "--temp", "0.0",
                "--top-p", "0.9",
                "--no-display-prompt",
                "--no-show-timings"
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

            let didExit = await Self.waitForExit(process, timeoutNanoseconds: 180_000_000_000)
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

    nonisolated private static func optimalThreadCount() -> Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    nonisolated private static func availableLocalPort() throws -> Int {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw TranscriptRefinementServiceError.failedToRun("Could not create a local socket for llama-server.")
        }

        defer {
            Darwin.close(socketDescriptor)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            throw TranscriptRefinementServiceError.failedToRun("Could not reserve a local port for llama-server.")
        }

        var resolvedAddress = sockaddr_in()
        var resolvedAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &resolvedAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.getsockname(socketDescriptor, sockaddrPointer, &resolvedAddressLength)
            }
        }

        guard nameResult == 0 else {
            throw TranscriptRefinementServiceError.failedToRun("Could not inspect the local port for llama-server.")
        }

        return Int(UInt16(bigEndian: resolvedAddress.sin_port))
    }

    private enum PromptProfile {
        case compact
        case standard
    }

    nonisolated private static func makePrompt(
        transcript: String,
        whisperTaskMode: WhisperTaskMode,
        configuration: RefinementConfiguration
    ) -> String {
        let instructions = promptInstructions(
            for: promptProfile(for: configuration.model),
            whisperTaskMode: whisperTaskMode
        )

        return """
        <|im_start|>system
        \(instructions)<|im_end|>
        <|im_start|>user
        \(transcript)<|im_end|>
        <|im_start|>assistant
        """
    }

    nonisolated private static func promptProfile(for model: RefinementModelDescriptor) -> PromptProfile {
        switch model {
        case .qwen25HalfB:
            return .compact
        case .qwen25OneAndHalfB, .qwen25ThreeB, .smolLM2OnePointSevenB:
            return .standard
        }
    }

    nonisolated private static func promptInstructions(
        for profile: PromptProfile,
        whisperTaskMode: WhisperTaskMode
    ) -> String {
        let languageInstruction: String
        switch whisperTaskMode {
        case .transcribe:
            languageInstruction = "Preserve the original language."
        case .translateToEnglish:
            languageInstruction = "Output English."
        }

        switch profile {
        case .compact:
            return """
            Clean up the transcript.
            Output only the corrected text.
            \(languageInstruction)

            Rules:
            - Preserve meaning.
            - Preserve names, numbers, dates, URLs, code, and commands.
            - Remove filler words, repetitions, false starts, and speech disfluencies.
            - Resolve self-corrections by keeping the final intended wording.
            - Fix grammar, punctuation, capitalization, and spacing.
            - Rewrite awkward dictated speech into natural written language.
            - Do not add information.
            - Do not explain changes.
            """

        case .standard:
            return """
            Clean up the transcript.
            Output only the corrected text.
            \(languageInstruction)

            Rules:
            - Preserve meaning.
            - Preserve names, numbers, dates, URLs, code, and commands.
            - Remove filler words, repetitions, false starts, and speech disfluencies.
            - Resolve self-corrections by keeping the final intended wording.
            - Fix grammar, punctuation, capitalization, and spacing.
            - Rewrite awkward dictated speech into natural written language.
            - Compress redundant wording.
            - Preserve distinct ideas, requests, facts, and action items.
            - Format paragraphs for readability.
            - Convert spoken enumerations into numbered lists when clearly intended.
            - Use bullet points for clear itemized lists.
            - Do not add information.
            - Do not explain changes.
            """
        }
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
