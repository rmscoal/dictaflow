import AVFoundation
import Foundation

struct LiquidSpeechRenderResult: Sendable {
    let speech: LiquidSpeech
    let validationSeconds: Double
}

/// Buffers a complete response before admission to playback. A failed/cancelled chunk
/// never returns a partial response. The request closure is the local runtime boundary.
enum LiquidSpeechRenderer {
    static func render(_ plan: LiquidSpeechPlan, deadline: ContinuousClock.Instant,
                       request: @Sendable (LiquidSpeechChunk) async throws -> Data) async throws -> LiquidSpeechRenderResult {
        var audio = LiquidSpeechAudio()
        var validationSeconds = 0.0
        var singleWAV: Data?
        for chunk in plan.chunks {
            try check(deadline)
            let wav = try await request(chunk)
            try check(deadline)
            let started = ContinuousClock.now
            try audio.append(wav, startsParagraph: chunk.startsParagraph)
            if plan.chunks.count == 1 { singleWAV = wav }
            validationSeconds += seconds(since: started)
        }
        try check(deadline)
        let started = ContinuousClock.now
        let speech = try audio.finish(originalWAV: singleWAV)
        validationSeconds += seconds(since: started)
        try check(deadline)
        return LiquidSpeechRenderResult(speech: speech, validationSeconds: validationSeconds)
    }

    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard .now < deadline else { throw VoiceError.unavailable("Agent speech exceeded its 60-second synthesis budget. Use a shorter spoken response.") }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// The pinned Liquid codec emits mono 24 kHz audio. Decode with AVFoundation and
/// re-encode one WAV; concatenating WAV file bytes would corrupt the result.
struct LiquidSpeechAudio {
    static let maxBytes = 12 * 1024 * 1024
    static let sampleRate = 24_000.0
    static let maxFrames = Int(sampleRate * 120)
    private var samples: [Float] = []
    private var receivedBytes = 0

    mutating func append(_ wav: Data, startsParagraph: Bool) throws {
        guard wav.count <= Self.maxBytes - receivedBytes else {
            throw VoiceError.unavailable("Generated speech exceeds the 12 MiB response limit. Use a shorter spoken response.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try wav.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == Self.sampleRate else {
            throw VoiceError.unavailable("Liquid returned an unexpected audio format. Expected mono 24 kHz speech.")
        }
        guard file.length > 0, file.length < Self.maxFrames,
              samples.count + Int(file.length) < Self.maxFrames else { throw Self.durationError() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceError.unavailable("Could not decode generated speech.")
        }
        try file.read(into: buffer)
        guard buffer.frameLength == file.length, let channel = buffer.floatChannelData?[0] else {
            throw VoiceError.unavailable("Liquid returned incomplete speech audio.")
        }
        let next = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard next.allSatisfy(\.isFinite) else { throw VoiceError.unavailable("Liquid returned invalid audio samples.") }
        if !samples.isEmpty {
            // Only pad a quiet boundary; never trim generated samples or risk clipping a word.
            // Existing quiet tails/heads count toward the gap, avoiding a doubled pause.
            let target = Int(Self.sampleRate * (startsParagraph ? 0.25 : 0.12))
            let tail = samples.reversed().prefix(target).prefix(while: { abs($0) <= 0.002 }).count
            let head = next.prefix(target).prefix(while: { abs($0) <= 0.002 }).count
            let padding = max(0, target - tail - head)
            guard samples.count + padding + next.count < Self.maxFrames else { throw Self.durationError() }
            samples.append(contentsOf: repeatElement(0, count: padding))
        }
        samples.append(contentsOf: next)
        receivedBytes += wav.count
    }

    func finish(originalWAV: Data? = nil) throws -> LiquidSpeech {
        guard !samples.isEmpty else { throw VoiceError.unavailable("Liquid returned no speech audio.") }
        if let originalWAV { return LiquidSpeech(wav: originalWAV, duration: Double(samples.count) / Self.sampleRate) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw VoiceError.unavailable("Could not assemble generated speech.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let wav = try Data(contentsOf: url)
        guard wav.count <= Self.maxBytes else { throw VoiceError.unavailable("Generated speech exceeds the 12 MiB response limit.") }
        return LiquidSpeech(wav: wav, duration: Double(samples.count) / Self.sampleRate)
    }

    private static func durationError() -> VoiceError {
        .unavailable("Generated speech is empty or exceeds the 120-second response limit. Use a shorter spoken response.")
    }
}
