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
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while oldProcess.isRunning && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if oldProcess.isRunning { Darwin.kill(oldProcess.processIdentifier, SIGKILL) }
                await Task.detached { oldProcess.waitUntilExit() }.value
            }
        }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    func refine(transcript: String, whisperTaskMode: WhisperTaskMode, modelURL: URL,
                configuration: RefinementConfiguration, promptTemplate: String) async throws -> TranscriptRefinementResult {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptRefinementServiceError.emptyOutput }
        let url = try await ensureServer(modelURL: modelURL)
        let started = ContinuousClock.now
        let json = try await post(path: "v1/chat/completions", baseURL: url, payload: [
            "messages": [
                ["role": "system", "content": RefinementPromptTemplate.renderedInstructions(from: promptTemplate, whisperTaskMode: whisperTaskMode)],
                ["role": "user", "content": text]
            ],
            "max_tokens": RefinementInference.maximumOutputTokens(for: text),
            "temperature": 0.2, "top_p": 0.9, "top_k": 0, "min_p": 0,
            "chat_template_kwargs": ["enable_thinking": false], "stream": false
        ])
        guard let choice = (json["choices"] as? [[String: Any]])?.first else {
            throw TranscriptRefinementServiceError.emptyOutput
        }
        guard choice["finish_reason"] as? String == "stop" else {
            throw TranscriptRefinementServiceError.incompleteOutput
        }
        let content = (choice["message"] as? [String: Any])?["content"] as? String ?? ""
        let result = try RefinementInference.result(content, original: transcript, configuration: configuration)
        let usage = json["usage"] as? [String: Any]
        logger.info("llama refinement duration=\(String(describing: started.duration(to: .now)), privacy: .public) outputTokens=\(usage?["completion_tokens"] as? Int ?? 0)")
        return result
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
    nonisolated static func maximumOutputTokens(for transcript: String) -> Int {
        min(1024, max(128, transcript.count / 3))
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
