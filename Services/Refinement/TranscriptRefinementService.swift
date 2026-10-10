import Darwin
import Foundation
import OSLog

nonisolated protocol TranscriptRefinementServiceProtocol: AnyObject {
    func isRuntimeAvailable(for model: RefinementModelDescriptor) async -> Bool
    func prepare(modelURL: URL) async throws
    func reloadModels() async
    func stop() async
    func refine(transcript: String, whisperTaskMode: WhisperTaskMode, modelURL: URL,
                configuration: RefinementConfiguration, promptTemplate: String) async throws -> TranscriptRefinementResult
}

nonisolated enum TranscriptRefinementServiceError: LocalizedError {
    case missingRuntime
    case failedToRun(String)
    case timedOut
    case emptyOutput
    case incompleteOutput

    var errorDescription: String? {
        switch self {
        case .missingRuntime: "The local refinement runtime is unavailable. Reinstall DictaFlow and try again."
        case .failedToRun(let details): "The local model could not clean the transcript. \(details)"
        case .timedOut: "The local refinement model took too long to respond."
        case .emptyOutput: "The local refinement model returned an empty result."
        case .incompleteOutput: "The refinement was incomplete. Your original transcript will be used."
        }
    }
}

/// One model needs only one server process. Idle sleep releases weights and KV cache.
actor LlamaCLITranscriptRefinementService: TranscriptRefinementServiceProtocol {
    private let executableURL: URL?
    private let urlSession: URLSession
    private let idleSleepSeconds: Int
    private var process: Process?
    private var modelURL: URL?
    private var baseURL: URL?
    private var startupTask: Task<URL, Error>?
    private var serverID = UUID()
    private var shutdownTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "DictaFlow", category: "Refinement")

    init(executableURL: URL? = nil, urlSession: URLSession = .shared, idleSleepSeconds: Int = 300) {
        self.executableURL = executableURL
        self.urlSession = urlSession
        self.idleSleepSeconds = idleSleepSeconds
    }

    func isRuntimeAvailable(for model: RefinementModelDescriptor) async -> Bool {
        (try? resolveRuntimeURL()) != nil
    }

    func reloadModels() async {}

    func prepare(modelURL: URL) async throws {
        let url = try await ensureServer(modelURL: modelURL)
        // /health does not wake sleeping models. A zero-output completion does.
        var props = URLRequest(url: url.appendingPathComponent("props"))
        props.timeoutInterval = 5
        let (data, _) = try await urlSession.data(for: props)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if json?["is_sleeping"] as? Bool == true {
            _ = try await post(path: "completion", baseURL: url, payload: ["prompt": "", "n_predict": 0])
        }
        try Task.checkCancellation()
    }

    func stop() async {
        if let shutdownTask { await shutdownTask.value; return }
        serverID = UUID()
        startupTask?.cancel()
        startupTask = nil
        guard let oldProcess = process else { return }
        process = nil
        modelURL = nil
        baseURL = nil
        let task = Task {
            if oldProcess.isRunning {
                oldProcess.terminate()
                if !(await Self.waitForExit(of: oldProcess, timeout: .seconds(3))) {
                    Darwin.kill(oldProcess.processIdentifier, SIGKILL)
                    if !(await Self.waitForExit(of: oldProcess, timeout: .seconds(1))) {
                        logger.error("Refinement runtime exit was not observed after forced shutdown.")
                    }
                }
            }
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    // Foundation observes and reaps Process exits. Poll asynchronously instead of
    // calling waitUntilExit(), which can stall on a background thread's run loop.
    nonisolated private static func waitForExit(of process: Process, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }

    func refine(transcript: String, whisperTaskMode: WhisperTaskMode, modelURL: URL,
                configuration: RefinementConfiguration, promptTemplate: String) async throws -> TranscriptRefinementResult {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptRefinementServiceError.emptyOutput }
        let url = try await ensureServer(modelURL: modelURL)
        let started = ContinuousClock.now
        let instructions = RefinementPromptTemplate.renderedInstructions(from: promptTemplate, whisperTaskMode: whisperTaskMode)
        // Measure using the loaded model's tokenizer, including its own chat template.
        let chunks = try await boundedChunks(text, instructions: instructions, baseURL: url)
        // Short dictations retain the original single-request path.
        if chunks.count == 1 {
            let output = try await rewrite(messages: messages(instructions: instructions, text: text),
                                           configuration: configuration, baseURL: url)
            logger.info("llama refinement duration=\(String(describing: started.duration(to: .now)), privacy: .public) sourceChunks=1")
            return try RefinementInference.result(output, original: transcript, configuration: configuration)
        }

        let rollingInstructions = instructions + """


        This transcript is being edited in parts. The preceding assistant message,
        if present, is earlier output provided only for context. Do not repeat it.
        Rewrite only the latest user message. Its beginning may be an editable
        ending from the previous part. Resolve self-corrections across that ending
        and the new speech. Continue list numbering from the earlier output;
        preserve existing item numbers unless the speaker corrects them.
        Do not summarize. Preserve every distinct request, condition, and corrected
        date, even when the surrounding speech is repetitive.
        """
        var pending = chunks
        var committed = ""
        var editableEnding = ""
        var earlierContext = ""
        while !pending.isEmpty {
            try Task.checkCancellation()
            let chunk = pending.removeFirst()
            let input = editableEnding.isEmpty ? chunk : editableEnding + "\n\n" + chunk
            var requestMessages = [["role": "system", "content": rollingInstructions]]
            if !earlierContext.isEmpty {
                requestMessages.append(["role": "assistant", "content": earlierContext])
            }
            requestMessages.append(["role": "user", "content": input])
            // Count the exact multi-turn template, including read-only context.
            let promptTokens = try await promptTokenCount(messages: requestMessages, baseURL: url)
            let inputTokens = try await tokenCount(input, baseURL: url)
            if promptTokens > 2400 || inputTokens > 900 {
                guard let split = RefinementInference.splitNearMiddle(chunk) else {
                    throw TranscriptRefinementServiceError.failedToRun("The system prompt is too long for contextual refinement. Shorten your instructions.")
                }
                pending.insert(contentsOf: [split.0, split.1], at: 0)
                continue
            }
            let output = try await rewrite(messages: requestMessages, configuration: configuration, baseURL: url)
            if pending.isEmpty {
                committed += output
            } else {
                // Delay committing the ending until the next source chunk is seen.
                // Split the generated output itself, so overlapping input is never
                // appended twice and earlier wording can still be corrected.
                var ending = output
                var prefix = ""
                while try await tokenCount(ending, baseURL: url) > 450 {
                    guard let split = RefinementInference.splitNearMiddle(ending) else {
                        throw TranscriptRefinementServiceError.incompleteOutput
                    }
                    prefix += split.0
                    ending = split.1
                }
                if !prefix.isEmpty {
                    committed += prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
                    earlierContext = try await contextSuffix(committed, baseURL: url)
                }
                editableEnding = ending.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let result = try RefinementInference.result(committed, original: transcript, configuration: configuration)
        logger.info("llama refinement duration=\(String(describing: started.duration(to: .now)), privacy: .public) sourceChunks=\(chunks.count)")
        return result
    }

    private func rewrite(messages: [[String: String]], configuration: RefinementConfiguration, baseURL: URL) async throws -> String {
        var payload: [String: Any] = [
            "messages": messages, "max_tokens": 1536,
            "temperature": 0.2, "top_p": 0.9, "top_k": 0, "min_p": 0,
            "stream": false
        ]
        if configuration.model.provider == .qwen || configuration.model.provider == .google {
            payload["chat_template_kwargs"] = ["enable_thinking": false]
        }
        let json = try await post(path: "v1/chat/completions", baseURL: baseURL, payload: payload)
        guard let choice = (json["choices"] as? [[String: Any]])?.first else {
            throw TranscriptRefinementServiceError.emptyOutput
        }
        guard choice["finish_reason"] as? String == "stop" else {
            throw TranscriptRefinementServiceError.incompleteOutput
        }
        let content = (choice["message"] as? [String: Any])?["content"] as? String ?? ""
        return try RefinementInference.result(content, original: "", configuration: configuration).refinedText
    }

    private func contextSuffix(_ text: String, baseURL: URL) async throws -> String {
        // Only a small recent context is needed to continue numbering and style.
        var context = String(text.suffix(800))
        while try await tokenCount(context, baseURL: baseURL) > 200 {
            context = String(context.suffix(context.count / 2))
        }
        return context
    }

    private func messages(instructions: String, text: String) -> [[String: String]] {
        [["role": "system", "content": instructions], ["role": "user", "content": text]]
    }

    private func tokenCount(_ text: String, baseURL: URL) async throws -> Int {
        let tokenized = try await post(path: "tokenize", baseURL: baseURL, payload: ["content": text])
        guard let tokens = tokenized["tokens"] as? [Int] else {
            throw TranscriptRefinementServiceError.failedToRun("Could not tokenize the transcript.")
        }
        return tokens.count
    }

    private func promptTokenCount(messages: [[String: String]], baseURL: URL) async throws -> Int {
        let rendered = try await post(path: "apply-template", baseURL: baseURL,
            payload: ["messages": messages, "chat_template_kwargs": ["enable_thinking": false]])
        guard let prompt = rendered["prompt"] as? String else {
            throw TranscriptRefinementServiceError.failedToRun("Could not measure the model's context budget.")
        }
        let tokenized = try await post(path: "tokenize", baseURL: baseURL,
            payload: ["content": prompt, "add_special": true, "parse_special": true])
        guard let tokens = tokenized["tokens"] as? [Int] else {
            throw TranscriptRefinementServiceError.failedToRun("Could not tokenize the transcript.")
        }
        return tokens.count
    }

    private func boundedChunks(_ text: String, instructions: String, baseURL: URL) async throws -> [String] {
        var pending = [text]
        var chunks: [String] = []
        while let candidate = pending.first {
            pending.removeFirst()
            try Task.checkCancellation()
            let promptTokens = try await promptTokenCount(messages: messages(instructions: instructions, text: candidate), baseURL: baseURL)
            let sourceTokens = try await tokenCount(candidate, baseURL: baseURL)
            // 4096 context minus 1536 output tokens and template/special-token margin.
            if promptTokens <= 2400 && sourceTokens <= 900 {
                chunks.append(candidate)
            } else {
                guard let split = RefinementInference.splitNearMiddle(candidate) else {
                    throw TranscriptRefinementServiceError.failedToRun("The system prompt is too long for the model's context. Shorten your instructions.")
                }
                pending.insert(contentsOf: [split.0, split.1], at: 0)
            }
        }
        return chunks
    }

    private func ensureServer(modelURL: URL) async throws -> URL {
        try Task.checkCancellation()
        if self.modelURL == modelURL, let startupTask { return try await startupTask.value }
        if self.modelURL == modelURL, process?.isRunning == true, let baseURL { return baseURL }
        await stop()
        try Task.checkCancellation()
        if process != nil { return try await ensureServer(modelURL: modelURL) }
        let runtime = try resolveRuntimeURL()
        let port = try Self.availableLocalPort()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let newProcess = Process()
        newProcess.executableURL = runtime
        newProcess.arguments = [
            "--model", modelURL.path, "--host", "127.0.0.1", "--port", "\(port)",
            "--n-gpu-layers", "all", "--flash-attn", "auto",
            "--threads", "\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))",
            "--threads-batch", "\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))",
            "--ctx-size", "4096", "--batch-size", "512", "--parallel", "1",
            "--sleep-idle-seconds", "\(idleSleepSeconds)", "--no-context-shift",
            "--chat-template-kwargs", "{\"enable_thinking\":false}", "--reasoning-budget", "0",
            "--no-ui", "--no-webui", "--log-disable"
        ]
        newProcess.standardOutput = FileHandle.nullDevice
        newProcess.standardError = FileHandle.nullDevice
        try newProcess.run()
        let id = UUID()
        serverID = id
        process = newProcess
        self.modelURL = modelURL
        baseURL = url
        let task = Task { try await self.waitForReady(url: url, process: newProcess) }
        startupTask = task
        do {
            let readyURL = try await task.value
            try Task.checkCancellation()
            guard serverID == id else { throw CancellationError() }
            startupTask = nil
            return readyURL
        } catch {
            if serverID == id { await stop() }
            throw error
        }
    }

    private func waitForReady(url: URL, process: Process) async throws -> URL {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw TranscriptRefinementServiceError.failedToRun("The runtime exited while loading the model.")
            }
            var request = URLRequest(url: url.appendingPathComponent("health"))
            request.timeoutInterval = 2
            do {
                let (_, response) = try await urlSession.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 { return url }
            } catch {
                try Task.checkCancellation()
            }
            // Pause for both network errors and unsuccessful HTTP responses.
            try await Task.sleep(for: .milliseconds(250))
        }
        throw TranscriptRefinementServiceError.timedOut
    }

    private func post(path: String, baseURL: URL, payload: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await urlSession.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TranscriptRefinementServiceError.failedToRun("The runtime rejected the request. The transcript may exceed its context limit.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptRefinementServiceError.failedToRun("The runtime returned an invalid response.")
        }
        return json
    }

    private func resolveRuntimeURL() throws -> URL {
        if let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) { return executableURL }
        if let url = Bundle.main.url(forAuxiliaryExecutable: "llama-server"), FileManager.default.isExecutableFile(atPath: url.path) { return url }
        #if DEBUG
        for path in ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        #endif
        throw TranscriptRefinementServiceError.missingRuntime
    }

    nonisolated private static func availableLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TranscriptRefinementServiceError.failedToRun("Could not open a local socket.") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw TranscriptRefinementServiceError.failedToRun("Could not reserve a local port.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard inspected == 0 else { throw TranscriptRefinementServiceError.failedToRun("Could not inspect a local port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Shared limits and output checks keep both backends' insertion behavior consistent.
enum RefinementInference {
    /// Prefer paragraph and sentence boundaries; never overlap chunks or repeat source text.
    nonisolated static func splitNearMiddle(_ text: String) -> (String, String)? {
        guard text.count > 128 else { return nil }
        let chars = Array(text)
        let middle = chars.count / 2
        let radius = chars.count / 4
        var boundary: Int?
        for predicate: (Character) -> Bool in [{ $0 == "\n" }, { ".!?。！？".contains($0) }, { $0.isWhitespace }] {
            for distance in 0...radius {
                for index in [middle - distance, middle + distance] where index > 0 && index < chars.count - 1 {
                    if predicate(chars[index]) { boundary = index + 1; break }
                }
                if boundary != nil { break }
            }
            if boundary != nil { break }
        }
        let split = boundary ?? middle
        return (String(chars[..<split]), String(chars[split...]))
    }

    nonisolated static func result(_ output: String, original: String, configuration: RefinementConfiguration) throws -> TranscriptRefinementResult {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptRefinementServiceError.emptyOutput }
        // Reasoning and template delimiters must never be inserted into another app.
        guard !text.contains("<think>"), !text.contains("</think>"), !text.contains("<|im_") else {
            throw TranscriptRefinementServiceError.incompleteOutput
        }
        return TranscriptRefinementResult(originalText: original, refinedText: text, model: configuration.model,
            mode: configuration.mode, completedAt: Date())
    }
}
