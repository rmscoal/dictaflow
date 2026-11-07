@testable import AgentVoice
import AVFoundation
import Foundation
import Testing

struct LiquidSpeechTests {
    @Test func historicalLongResponseIsBoundedWithoutLosingWords() throws {
        let plan = try LiquidSpeechPlan.make(Self.historicalReview)
        #expect(plan.chunks.count >= 6)
        #expect(plan.chunks.allSatisfy { $0.language == "en" })
        #expect(plan.chunks.allSatisfy { $0.text.count <= 320 && $0.text.split(whereSeparator: \.isWhitespace).count <= 50 })
        #expect(plan.chunks.filter(\.startsParagraph).count == 3)
        #expect(words(plan.chunks.map(\.text).joined(separator: " ")) == words(Self.historicalReview))
        #expect(plan.chunks.first?.text.hasSuffix("visible interruption controls.") == true)
    }

    @Test func threeShortSentencesCanShareOneChunkButNeverFour() throws {
        let text = "Speech stays local. Dictation has priority. Playback can stop. History stays separate."
        let chunks = try englishPlan(text).chunks
        #expect(chunks.count == 2)
        #expect(chunks[0].text == "Speech stays local. Dictation has priority. Playback can stop.")
        #expect(!chunks[1].startsParagraph)
    }

    @Test func paragraphsAndWrappedLinesKeepTheirMeaning() throws {
        let text = "Dr. Lee checked version 1.5\r\nand the 12:30 recording.\r\n \r\nThe result is ready."
        let chunks = try englishPlan(text).chunks
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.startsParagraph })
        #expect(chunks[0].text == "Dr. Lee checked version 1.5 and the 12:30 recording.")
    }

    @Test func oversizedSentenceSplitsAtClausesThenWordsWithoutOmissions() throws {
        let text = (1...90).map { "detail\($0)" }.joined(separator: " ") + ", followed by the final caveat."
        let chunks = try englishPlan(text).chunks
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.text.count <= 320 && words($0.text).count <= 50 })
        #expect(words(chunks.map(\.text).joined(separator: " ")) == words(text))
        let identifier = try englishPlan("Read " + String(repeating: "x", count: 400))
        #expect(identifier.chunks.first?.text == "Read \(LiquidSpeechText.identifierNotice)")
    }

    @Test func chineseUsesConservativeGraphemeSafeLimits() throws {
        let text = String(repeating: "这是一个本地语音测试", count: 20) + "。"
        let chunks = try LiquidSpeechPlan.make(text, recognizer: FixedRecognizer(code: "zh-Hans")).chunks
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.text.count <= 60 && $0.language == "zh" })
        #expect(chunks.map(\.text).joined() == text)
    }

    @Test func languageIsChosenPerParagraphAndShortHeadingsUseContext() throws {
        let text = "The application keeps all generated speech on this computer.\n\nModels\n\nBonjour, cette application fonctionne sur votre ordinateur et conserve vos données localement."
        let chunks = try LiquidSpeechPlan.make(text, recognizer: ParagraphRecognizer()).chunks
        #expect(chunks.map(\.language) == ["en", "en", "fr"])
        #expect(LiquidRuntime.ttsPayload(text: "Bonjour", seed: nil, language: "fr")["lang"] as? String == "fr")
    }

    @Test func unsupportedAndUndeterminedLanguagesFailInsteadOfForcingEnglish() throws {
        #expect(throws: VoiceError.self) {
            try LiquidSpeechPlan.make("Tolong kirim laporan itu besok pagi dan simpan semua data di komputer saya.",
                                      recognizer: FixedRecognizer(code: "id"))
        }
        #expect(throws: VoiceError.self) {
            try LiquidSpeechPlan.make("This longer response has no reliable language signal.", recognizer: FixedRecognizer(code: nil))
        }
        let short = try LiquidSpeechPlan.make("OK.", recognizer: FixedRecognizer(code: nil))
        #expect(short.chunks.first?.language == "en")
    }

    @Test func systemRecognizerHandlesSupportedAndUnsupportedProse() throws {
        let french = try LiquidSpeechPlan.make("Bonjour, cette application conserve les données sur votre ordinateur. Vous pouvez arrêter la lecture à tout moment.")
        #expect(french.chunks.allSatisfy { $0.language == "fr" && $0.text.count <= 160 })
        #expect(throws: VoiceError.self) {
            try LiquidSpeechPlan.make("Saya ingin aplikasi ini membaca jawaban dalam bahasa Indonesia. Semua rekaman dan data harus tetap disimpan di komputer saya.")
        }
    }

    @Test func audioAssemblyPreservesSamplesAndUsesParagraphBoundaries() throws {
        var audio = LiquidSpeechAudio()
        try audio.append(wav(Array(repeating: 0.1, count: 2400)), startsParagraph: true)
        try audio.append(wav(Array(repeating: -0.1, count: 2400)), startsParagraph: false)
        try audio.append(wav(Array(repeating: 0.2, count: 2400)), startsParagraph: true)
        let speech = try audio.finish()
        let decoded = try samples(speech.wav)
        #expect(decoded.count == 16_080)
        #expect(abs(speech.duration - 0.67) < 0.0001)
        #expect(abs(decoded[0] - 0.1) < 0.0001)
        #expect(decoded[2400..<5280].allSatisfy { $0 == 0 })
        #expect(abs(decoded[5280] + 0.1) < 0.0001)
        #expect(decoded[7680..<13680].allSatisfy { $0 == 0 })
        #expect(abs(decoded[13680] - 0.2) < 0.0001)
    }

    @Test func existingQuietAudioIsNotTrimmedOrDoubled() throws {
        let first = Array(repeating: Float(0.1), count: 1000) + Array(repeating: Float(0), count: 4800)
        let next = Array(repeating: Float(0), count: 2400) + Array(repeating: Float(-0.1), count: 1000)
        var audio = LiquidSpeechAudio()
        try audio.append(wav(first), startsParagraph: true)
        try audio.append(wav(next), startsParagraph: true)
        #expect(try samples(audio.finish().wav).count == first.count + next.count)
    }

    @Test func aggregateLimitsAndUnexpectedAudioFailExplicitly() throws {
        var audio = LiquidSpeechAudio()
        let minute = try wav(Array(repeating: 0, count: 24_000 * 60))
        try audio.append(minute, startsParagraph: true)
        #expect(throws: VoiceError.self) { try audio.append(minute, startsParagraph: false) }
        #expect(throws: VoiceError.self) {
            try audio.append(Data(count: LiquidSpeechAudio.maxBytes - minute.count + 1), startsParagraph: false)
        }
        var empty = LiquidSpeechAudio()
        #expect(throws: VoiceError.self) { try empty.append(Data(count: LiquidSpeechAudio.maxBytes + 1), startsParagraph: true) }
        #expect(throws: VoiceError.self) { try empty.append(wav([0, 0], rate: 16_000), startsParagraph: true) }
        #expect(throws: VoiceError.self) { try empty.append(wav([0, .nan], floatPCM: true), startsParagraph: true) }
        #expect(throws: (any Error).self) { try empty.append(Data("not audio".utf8), startsParagraph: true) }
        #expect(throws: VoiceError.self) { try empty.finish() }
    }

    @Test func singleChunkKeepsOriginalWAVBytes() async throws {
        let data = try wav(Array(repeating: 0.1, count: 2400))
        let rendered = try await LiquidSpeechRenderer.render(englishPlan("The result is ready."), deadline: .now.advanced(by: .seconds(1))) { _ in data }
        #expect(rendered.speech.wav == data)
    }

    @Test func laterChunkFailureReturnsNoPartialResponse() async throws {
        let fixture = ChunkRequestFixture(wav: try wav(Array(repeating: 0.1, count: 2400)), failsSecond: true)
        let plan = try englishPlan("First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")
        await #expect(throws: VoiceError.self) {
            try await LiquidSpeechRenderer.render(plan, deadline: .now.advanced(by: .seconds(1))) { chunk in
                try await fixture.request(chunk)
            }
        }
        #expect(await fixture.calls == 2)
    }

    @Test func cancellationFencesLateChunkBeforeAnyFurtherRequest() async throws {
        let fixture = ChunkRequestFixture(wav: try wav(Array(repeating: 0.1, count: 2400)), suspendFirst: true)
        let plan = try englishPlan("First paragraph.\n\nSecond paragraph.")
        let task = Task {
            try await LiquidSpeechRenderer.render(plan, deadline: .now.advanced(by: .seconds(2))) { chunk in
                try await fixture.request(chunk)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await fixture.isSuspended), .now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await fixture.isSuspended)
        task.cancel()
        await fixture.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.calls == 1)
    }

    @Test func deadlineAppliesToTheEntireResponse() async throws {
        let data = try wav(Array(repeating: 0.1, count: 2400))
        await #expect(throws: VoiceError.self) {
            try await LiquidSpeechRenderer.render(englishPlan("First paragraph.\n\nSecond paragraph."), deadline: .now.advanced(by: .milliseconds(10))) { _ in
                try await Task.sleep(for: .milliseconds(30))
                return data
            }
        }
    }

    private func englishPlan(_ text: String) throws -> LiquidSpeechPlan {
        try LiquidSpeechPlan.make(text, recognizer: FixedRecognizer(code: "en"))
    }

    private func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    private func wav(_ values: [Float], rate: Double = 24_000, floatPCM: Bool = false) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
        buffer.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: values.count) }
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: floatPCM ? 32 : 16, AVLinearPCMIsFloatKey: floatPCM]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    private func samples(_ wav: Data) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try wav.write(to: url)
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    static let historicalReview = """
    I’d rate this as a promising beta, around six and a half out of ten for product readiness. The product direction is coherent: speech is local, dictation gets audio priority, users can choose automatic or manual playback, and there are visible interruption controls. The revision and suppression rules also address some of the confusing cases around delayed host events.

    The main launch risk is setup and trust. The feature asks users to configure hooks in external coding agents, and the docs themselves say lifecycle signals are best effort, configuration does not prove hooks are active, and supported versions need checking. The setup flow should make those host differences and the readiness state very clear. There is also a sizable onboarding burden: users must enable Agent Voice, install host configuration, download a large shared Liquid model, then understand two playback modes and a separate history surface.

    Liquid integration appears mostly consistent with the existing press to start, press to stop flow. But model discovery is split: selecting Liquid in transcription settings sends users to Agent Voice to download assets. That is understandable because the model is shared, though it could feel like an unexpected settings detour. I reviewed the diff and ran git diff --check, which passed. I did not run the app or tests, so visual polish and real host setup behavior remain unverified.
    """
}

private struct FixedRecognizer: LiquidLanguageRecognizing {
    let code: String?
    func hypotheses(for text: String) -> [String: Double] { code.map { [$0: 1] } ?? [:] }
}

private struct ParagraphRecognizer: LiquidLanguageRecognizing {
    func hypotheses(for text: String) -> [String: Double] {
        if text.contains("\n\n") { return [:] }
        if text.hasPrefix("Bonjour") { return ["fr": 1] }
        if text == "Models" { return ["nl": 1] }
        return ["en": 1]
    }
}

private actor ChunkRequestFixture {
    let wav: Data
    let failsSecond: Bool
    let suspendFirst: Bool
    var calls = 0
    var isSuspended: Bool { continuation != nil }
    private var continuation: CheckedContinuation<Void, Never>?
    init(wav: Data, failsSecond: Bool = false, suspendFirst: Bool = false) {
        self.wav = wav; self.failsSecond = failsSecond; self.suspendFirst = suspendFirst
    }
    func request(_ chunk: LiquidSpeechChunk) async throws -> Data {
        calls += 1
        if failsSecond && calls == 2 { throw VoiceError.unavailable("Second chunk failed.") }
        if suspendFirst && calls == 1 { await withCheckedContinuation { continuation = $0 } }
        return wav
    }
    func release() { continuation?.resume(); continuation = nil }
}
