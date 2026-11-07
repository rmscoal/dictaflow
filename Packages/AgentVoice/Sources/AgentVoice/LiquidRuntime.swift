import AVFoundation
import Darwin
import Foundation
import OSLog

/// Local diagnostic timings. Contains no rendition text, audio, paths, or credentials.
public struct LiquidSynthesisTimings: Codable, Sendable {
    public let startupSeconds: Double
    public let requestSeconds: Double
    public let responseHeaderSeconds: Double
    public let responseBodySeconds: Double
    public let validationSeconds: Double
}

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

/// Benchmark/test-only overrides. Production uses `.productionDefault`, which
/// preserves the exact inherited environment, argument shape, and unseeded payload.
public struct LiquidRuntimeConfiguration: Sendable {
    public var ttsSeed: UInt32?
    /// Trusted diagnostic-only flags for the bundled benchmark harness. Never
    /// wired to user preferences or host-supplied settings.
    public var extraServerArguments: [String]
    public var serverEnvironment: [String: String]?
    public var healthPollInterval: Duration

    public static let productionDefault = LiquidRuntimeConfiguration()

    /// 20 ms readiness polling: measured ~20 ms faster startup detection
    /// than 100 ms with no behavior change (2026-11-02, M2 Pro). Cost is a
    /// few dozen extra loopback health checks during sub-second startup.
    public init(ttsSeed: UInt32? = nil, extraServerArguments: [String] = [],
                serverEnvironment: [String: String]? = nil,
                healthPollInterval: Duration = .milliseconds(20)) {
        self.ttsSeed = ttsSeed
        self.extraServerArguments = extraServerArguments
        self.serverEnvironment = serverEnvironment
        self.healthPollInterval = healthPollInterval
    }
}

/// One owned sidecar, serial requests. Cancellation fences results and retires that process.
public actor LiquidRuntime: LiquidRuntimeProtocol {
    public private(set) var lastSynthesisTimings: LiquidSynthesisTimings?
    public private(set) var lastStopSeconds: Double = 0
    private let logger = Logger(subsystem: "com.dictaflow.agentvoice", category: "LiquidRuntime")
    private let executable: URL
    private let assets: LiquidAssets
    private let configuration: LiquidRuntimeConfiguration
    private var process: Process?
    private var endpoint: URL?
    private var generation = UUID()
    private var busy = false
    private let http: URLSession
    private var apiKey = UUID().uuidString
    private var synthesisRequests = (seconds: 0.0, headers: 0.0, body: 0.0, bytes: 0)

    public init(executable: URL, assets: LiquidAssets,
                configuration: LiquidRuntimeConfiguration = .productionDefault) {
        self.executable = executable; self.assets = assets; self.configuration = configuration
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        http = URLSession(configuration: configuration)
    }

    public func synthesize(_ text: String) async throws -> LiquidSpeech {
        guard !busy else { throw VoiceError.unavailable("Liquid audio is busy.") }
        busy = true; defer { busy = false }
        lastSynthesisTimings = nil
        synthesisRequests = (0, 0, 0, 0)
        let token = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        do {
            let plan = try LiquidSpeechPlan.make(text)
            let startupStarted = ContinuousClock.now
            let endpoint = try await start(token: token)
            let startupSeconds = Self.seconds(since: startupStarted)
            let rendered = try await LiquidSpeechRenderer.render(plan, deadline: deadline) { chunk in
                try await self.synthesizeChunk(chunk, endpoint: endpoint, token: token, deadline: deadline)
            }
            try check(token)
            lastSynthesisTimings = LiquidSynthesisTimings(startupSeconds: startupSeconds, requestSeconds: synthesisRequests.seconds,
                                                         responseHeaderSeconds: synthesisRequests.headers, responseBodySeconds: synthesisRequests.body,
                                                         validationSeconds: rendered.validationSeconds)
            logger.info("TTS chunks=\(plan.chunks.count, privacy: .public) startup_seconds=\(startupSeconds, privacy: .public) request_seconds=\(self.synthesisRequests.seconds, privacy: .public) header_seconds=\(self.synthesisRequests.headers, privacy: .public) body_seconds=\(self.synthesisRequests.body, privacy: .public) validation_seconds=\(rendered.validationSeconds, privacy: .public) audio_seconds=\(rendered.speech.duration, privacy: .public)")
            return rendered.speech
        } catch {
            await stop()
            if let network = error as? URLError, network.code == .timedOut {
                throw VoiceError.unavailable("Agent speech took too long to generate. Use a shorter spoken response.")
            }
            throw error
        }
    }

    private func synthesizeChunk(_ chunk: LiquidSpeechChunk, endpoint: URL, token: UUID,
                                 deadline: ContinuousClock.Instant) async throws -> Data {
        try check(token)
        let payload = Self.ttsPayload(text: chunk.text, seed: configuration.ttsSeed, language: chunk.language)
        let started = ContinuousClock.now
        let response = try await post(endpoint.appendingPathComponent("tts"), payload: payload,
                                      maxBytes: LiquidSpeechAudio.maxBytes - synthesisRequests.bytes, deadline: deadline)
        try check(token)
        synthesisRequests.seconds += Self.seconds(since: started)
        synthesisRequests.headers += response.headerSeconds
        synthesisRequests.body += response.bodySeconds
        synthesisRequests.bytes += response.data.count
        return response.data
    }

    public func transcribe(wav: Data, english: Bool) async throws -> String {
        guard !busy else { throw VoiceError.unavailable("Liquid audio is busy.") }
        try Self.validateASRInput(wav)
        busy = true; defer { busy = false }
        let token = generation
        do {
            let endpoint = try await start(token: token)
            let payload: [String: Any] = ["model": "dictaflow-liquid", "stream": false, "max_tokens": 2048,
                "messages": [
                    ["role": "system", "content": english ? "Perform ASR in English." : "Perform ASR."],
                    ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": wav.base64EncodedString()]]]]
                ]]
            let response = try await post(endpoint.appendingPathComponent("v1/chat/completions"), payload: payload, maxBytes: 1024 * 1024)
            try check(token)
            struct Response: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String }
                    let message: Message
                    let finish_reason: String?
                }
                let choices: [Choice]
            }
            guard let choice = try JSONDecoder().decode(Response.self, from: response.data).choices.first else {
                throw VoiceError.unavailable("Liquid returned no transcription.")
            }
            guard choice.finish_reason != "length" else { throw VoiceError.unavailable("Liquid reached its transcription limit. Use a shorter recording.") }
            return choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { await stop(); throw error }
    }

    /// Bounded shutdown attempt. Callers check hasExited before admitting foreground inference.
    public func stop() async {
        let started = ContinuousClock.now
        defer {
            lastStopSeconds = Self.seconds(since: started)
        }
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
        logger.info("Liquid retirement_seconds=\(Self.seconds(since: started), privacy: .public) exited=\(!owned.isRunning, privacy: .public)")
    }

    public func hasExited() -> Bool { process?.isRunning != true }

    private static func seconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private func pauseDuringShutdown() async {
        // Cleanup still paces its polling when the inference caller has been cancelled.
        await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
    }

    /// Production payload keys are unchanged when no seed is configured.
    /// A configured seed is passed through to `/tts`, which reproduces
    /// byte-identical audio for the same text and seed.
    public static func ttsPayload(text: String, seed: UInt32?, language: String = "en") -> [String: Any] {
        var payload: [String: Any] = ["input": text, "lang": language, "voice": "female", "stream": false,
                                       "response_format": "wav", "n_predict": 2048, "repeat_penalty": 1.1]
        if let seed { payload["seed"] = seed }
        return payload
    }

    /// Test seam for the exact server invocation. Never logged: the api key
    /// travels as a command argument, so callers must redact its value.
    /// `--poll 0` disables spin-waiting for work: measured -75% server CPU
    /// seconds per single-request cycle with neutral wall time and
    /// byte-identical output (2026-11-02, M2 Pro). Single-request sidecars
    /// never benefit from polling; wakeup latency is negligible for one shot.
    public func serverArguments(apiKey: String, port: UInt16) -> [String] {
        ["--model", assets.directory.appendingPathComponent(LiquidAssets.files[0].name).path,
         "--mmproj", assets.directory.appendingPathComponent(LiquidAssets.files[1].name).path,
         "--host", "127.0.0.1", "--port", String(port), "--alias", "dictaflow-liquid",
         "--ctx-size", "4096", "--parallel", "1", "--no-webui", "--api-key", apiKey,
         "--poll", "0", "--poll-batch", "0"]
         + configuration.extraServerArguments
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
        owned.arguments = serverArguments(apiKey: apiKey, port: port)
        // A configured environment fully replaces inheritance so benchmark
        // candidates run isolated. Production leaves this unset (inherits).
        if let environment = configuration.serverEnvironment { owned.environment = environment }
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
            try await Task.sleep(for: configuration.healthPollInterval)
        }
        throw VoiceError.unavailable("Liquid audio took too long to start.")
    }

    private func post(_ url: URL, payload: [String: Any], maxBytes: Int,
                      deadline: ContinuousClock.Instant? = nil) async throws -> (data: Data, headerSeconds: Double, bodySeconds: Double) {
        guard maxBytes > 0 else { throw VoiceError.unavailable("Generated speech exceeds the 12 MiB response limit.") }
        let session: URLSession
        if let deadline {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0 else { throw VoiceError.unavailable("Agent speech exceeded its 60-second synthesis budget. Use a shorter spoken response.") }
            // Bound headers AND stalled bodies by the remaining whole-response budget.
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = seconds
            settings.timeoutIntervalForResource = seconds
            session = URLSession(configuration: settings)
        } else { session = http }
        defer { if deadline != nil { session.invalidateAndCancel() } }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        // Count while receiving so an unbounded response is never retained or played.
        let started = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request)
        let headerSeconds = Self.seconds(since: started)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceError.unavailable("Liquid audio rejected the request.") }
        if response.expectedContentLength > maxBytes { throw VoiceError.unavailable("Generated audio exceeds the output limit.") }
        var data = Data(); data.reserveCapacity(min(maxBytes, 1024 * 1024))
        let bodyStarted = ContinuousClock.now
        let bodyDeadline = deadline ?? ContinuousClock.now.advanced(by: .seconds(60))
        for try await byte in bytes {
            guard data.count < maxBytes, ContinuousClock.now < bodyDeadline else { throw VoiceError.unavailable("Liquid output exceeded the size or synthesis-time limit.") }
            data.append(byte)
        }
        return (data, headerSeconds, Self.seconds(since: bodyStarted))
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

    /// ASR input cap, derived from the pinned runtime, not copied from the TTS
    /// output cap. Estimated 2026-11-02 on b11960 (no retained raw token probe):
    /// 16 kHz mono input costs about
    /// 12.5 prompt tokens per second plus ~20 tokens of framing (5 s/83, 15 s/208,
    /// 30 s/395, 60 s/770 prompt tokens). With --ctx-size 4096 and max_tokens 2048
    /// reserved for the transcript, (2048-20)/12.5 is about 162 s. 120 s keeps
    /// 120*12.5+20+2048=3568 tokens, a 528-token margin, and keeps a normal
    /// 150 wpm transcript (about 400 tokens) well inside max_tokens. 8 MiB covers
    /// 120 s of 16 kHz mono float32 (7.68 MB, 7.32 MiB) with margin while bounding the
    /// base64 POST and transient memory. Longer clips fail explicitly; they are
    /// never truncated or auto-switched to another provider.
    public static let maxASRDuration: TimeInterval = 120
    public static let maxASRBytes = 8 * 1024 * 1024

    public static func validateASRInput(_ wav: Data) throws {
        guard wav.count <= maxASRBytes else {
            throw VoiceError.inputTooLong("Liquid ASR supports up to 8 MiB of audio. The recording is kept; use Whisper or a shorter recording.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try wav.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: temporary) }
        catch { throw VoiceError.unavailable("Liquid could not read the audio for recognition.") }
        let rate = file.processingFormat.sampleRate
        let frames = Double(file.length)
        guard rate.isFinite, rate > 0, frames.isFinite, frames >= 0 else {
            throw VoiceError.unavailable("Liquid could not read the audio length.")
        }
        let duration = frames / rate
        guard duration.isFinite else { throw VoiceError.unavailable("Liquid could not read the audio length.") }
        guard duration > 0 else { throw VoiceError.unavailable("The recorded audio is empty.") }
        guard duration <= maxASRDuration else {
            throw VoiceError.inputTooLong("Liquid ASR supports up to 2 minutes. The recording is kept; use Whisper or a shorter recording.")
        }
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
