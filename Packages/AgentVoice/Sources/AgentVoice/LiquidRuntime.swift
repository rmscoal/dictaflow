import AVFoundation
import Darwin
import Foundation

public struct LiquidSpeech: Sendable {
    public let wav: Data
    public let duration: TimeInterval
    public init(wav: Data, duration: TimeInterval) { self.wav = wav; self.duration = duration }
}

public protocol LiquidRuntimeProtocol: Sendable {
    func synthesize(_ text: String) async throws -> LiquidSpeech
    func transcribe(wav: Data, english: Bool) async throws -> String
    func stop() async
    func hasExited() async -> Bool
}

/// One owned sidecar, serial requests. Cancellation fences results and retires that process.
public actor LiquidRuntime: LiquidRuntimeProtocol {
    private let executable: URL
    private let assets: LiquidAssets
    private var process: Process?
    private var endpoint: URL?
    private var generation = UUID()
    private var busy = false
    private let http: URLSession
    private var apiKey = UUID().uuidString

    public init(executable: URL, assets: LiquidAssets) {
        self.executable = executable; self.assets = assets
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        http = URLSession(configuration: configuration)
    }

    public func synthesize(_ text: String) async throws -> LiquidSpeech {
        guard !busy else { throw VoiceError.unavailable("Liquid audio is busy.") }
        guard !text.isEmpty, text.count <= 8_000 else { throw VoiceError.unavailable("The spoken rendition is empty or too long.") }
        busy = true; defer { busy = false }
        let token = generation
        do {
            let endpoint = try await start(token: token)
            let payload: [String: Any] = ["input": text, "lang": "en", "voice": "female", "stream": false,
                                           "response_format": "wav", "n_predict": 2048, "repeat_penalty": 1.1]
            let data = try await post(endpoint.appendingPathComponent("tts"), payload: payload, maxBytes: 12 * 1024 * 1024)
            try check(token)
            let duration = try Self.validateWAV(data)
            return LiquidSpeech(wav: data, duration: duration)
        } catch {
            await stop()
            throw error
        }
    }

    public func transcribe(wav: Data, english: Bool) async throws -> String {
        guard !busy else { throw VoiceError.unavailable("Liquid audio is busy.") }
        busy = true; defer { busy = false }
        let token = generation
        do {
            let endpoint = try await start(token: token)
            let payload: [String: Any] = ["model": "dictaflow-liquid", "stream": false, "max_tokens": 2048,
                "messages": [
                    ["role": "system", "content": english ? "Perform ASR in English." : "Perform ASR."],
                    ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": wav.base64EncodedString()]]]]
                ]]
            let data = try await post(endpoint.appendingPathComponent("v1/chat/completions"), payload: payload, maxBytes: 1024 * 1024)
            try check(token)
            struct Response: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message
                    let finish_reason: String?
                }
                let choices: [Choice]
            }
            guard let choice = try JSONDecoder().decode(Response.self, from: data).choices.first else {
                throw VoiceError.unavailable("Liquid returned no transcription.")
            }
            guard choice.finish_reason != "length" else { throw VoiceError.unavailable("Liquid reached its transcription limit. Use a shorter recording.") }
            return choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { await stop(); throw error }
    }

    /// Bounded shutdown attempt. Callers check hasExited before admitting foreground inference.
    public func stop() async {
        generation = UUID()
        endpoint = nil
        guard let owned = process else { return }
        if owned.isRunning { owned.terminate() }
        let softDeadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        while owned.isRunning, ContinuousClock.now < softDeadline { await pauseDuringShutdown() }
        if owned.isRunning { kill(owned.processIdentifier, SIGKILL) }
        let hardDeadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while owned.isRunning, ContinuousClock.now < hardDeadline { await pauseDuringShutdown() }
        if !owned.isRunning, process === owned { process = nil }
    }

    public func hasExited() -> Bool { process?.isRunning != true }

    private func pauseDuringShutdown() async {
        // Cleanup still paces its polling when the inference caller has been cancelled.
        await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
    }

    private func start(token: UUID) async throws -> URL {
        try check(token)
        if let endpoint, process?.isRunning == true { return endpoint }
        guard process?.isRunning != true else { throw VoiceError.unavailable("The previous Liquid process has not exited yet.") }
        guard try await assets.isReady() else { throw VoiceError.unavailable("Download the Liquid audio model first.") }
        try check(token)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw VoiceError.unavailable("The bundled Liquid audio runtime is missing.") }
        let port = try Self.availablePort()
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let owned = Process()
        apiKey = UUID().uuidString
        owned.executableURL = executable
        owned.arguments = ["--model", assets.directory.appendingPathComponent(LiquidAssets.files[0].name).path,
                           "--mmproj", assets.directory.appendingPathComponent(LiquidAssets.files[1].name).path,
                           "--host", "127.0.0.1", "--port", String(port), "--alias", "dictaflow-liquid",
                           "--ctx-size", "4096", "--parallel", "1", "--no-webui", "--api-key", apiKey]
        owned.standardOutput = FileHandle.nullDevice; owned.standardError = FileHandle.nullDevice
        try owned.run()
        process = owned
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline {
            try check(token)
            guard owned.isRunning else { throw VoiceError.unavailable("Liquid audio could not load the model. Check available memory and model files.") }
            var request = URLRequest(url: endpoint.appendingPathComponent("health")); request.timeoutInterval = 1
            if let (_, response) = try? await http.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                try check(token); self.endpoint = endpoint; return endpoint
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw VoiceError.unavailable("Liquid audio took too long to start.")
    }

    private func post(_ url: URL, payload: [String: Any], maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        // Count while receiving so an unbounded response is never retained or played.
        let (bytes, response) = try await http.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceError.unavailable("Liquid audio rejected the request.") }
        if response.expectedContentLength > maxBytes { throw VoiceError.unavailable("Generated audio exceeds the output limit.") }
        var data = Data(); data.reserveCapacity(min(maxBytes, 1024 * 1024))
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        for try await byte in bytes {
            guard data.count < maxBytes, ContinuousClock.now < deadline else { throw VoiceError.unavailable("Liquid output exceeded the size or synthesis-time limit.") }
            data.append(byte)
        }
        return data
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    public static func validateWAV(_ data: Data) throws -> TimeInterval {
        guard data.count <= 12 * 1024 * 1024 else { throw VoiceError.unavailable("Generated audio exceeds 12 MiB.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try AVAudioFile(forReading: temporary)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > 0, duration.isFinite, duration < 120 else { throw VoiceError.unavailable("Generated audio is empty or exceeds the 120-second playback limit.") }
        return duration
    }

    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VoiceError.unavailable("Could not reserve a local audio port.") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0, resolved == 0 else { throw VoiceError.unavailable("Could not reserve a local audio port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
