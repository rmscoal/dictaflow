import Foundation
import XCTest
@testable import DictaFlow_Dev

/// Opt-in audio and pinned weights live outside the repository. Tests never download them.
@MainActor
final class WhisperIntegrationTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: "/tmp/DictaFlowWhisperFixtures", isDirectory: true)

    func testSpeechSilenceSpeechOnReusedContextAndAfterReload() async throws {
        let (model, modelURL) = try await verifiedModel()
        let audioURL = try fixtureURL("speech-en.wav")
        let decodedSpeech = try await AVAudioDecodingService().decodePCMFloatSamples(from: audioURL)
        let speech = [Float](repeating: 0, count: 16_000) + decodedSpeech
        let decoder = IntegrationPCMDecoder(samples: speech)
        let service = WhisperCPPService(audioDecodingService: decoder)
        var configuration = WhisperConfiguration.default
        configuration.model = model

        let first = try await service.transcribe(audioFileURL: audioURL, modelURL: modelURL, configuration: configuration)
        XCTAssertTrue(first.text.lowercased().contains("please send the report tomorrow"))
        let firstSegment = try XCTUnwrap(first.segments.first)
        XCTAssertGreaterThanOrEqual(firstSegment.startTime, 0.7, "Timestamps must include the original leading silence")
        assertTimestamps(first, duration: Double(speech.count) / 16_000)

        await decoder.setSamples([Float](repeating: 0, count: 16_000 * 2))
        let silence = try await service.transcribe(audioFileURL: audioURL, modelURL: modelURL, configuration: configuration)
        XCTAssertEqual(silence.text, "")
        XCTAssertTrue(silence.segments.isEmpty)
        XCTAssertNil(silence.detectedLanguageCode)

        await decoder.setSamples(speech)
        let repeated = try await service.transcribe(audioFileURL: audioURL, modelURL: modelURL, configuration: configuration)
        XCTAssertEqual(repeated.text, first.text)
        await service.unloadModel()
        let reloaded = try await service.transcribe(audioFileURL: audioURL, modelURL: modelURL, configuration: configuration)
        XCTAssertEqual(reloaded.text, first.text)
        await service.unloadModel()
    }

    func testRealEncoderWarmupBypassesMissingVADResource() async throws {
        let (model, modelURL) = try await verifiedModel()
        let decoder = IntegrationPCMDecoder(samples: [Float](repeating: 0, count: 8_000))
        let service = WhisperCPPService(audioDecodingService: decoder, vadModelURL: nil)
        var configuration = WhisperConfiguration.default
        configuration.model = model
        try await service.warmUpEncoder(audioFileURL: fixtures, modelURL: modelURL, configuration: configuration)
        await service.unloadModel()
    }

    func testRealCoreMLEncoderWarmupBypassesVAD() async throws {
        let (model, modelURL) = try await verifiedModel(required: .largeV3Turbo)
        _ = try fixtureURL(model.encoderDirectoryName)
        let decoder = IntegrationPCMDecoder(samples: [Float](repeating: 0, count: 8_000))
        let service = WhisperCPPService(audioDecodingService: decoder, vadModelURL: nil)
        var configuration = WhisperConfiguration.default
        configuration.model = model
        try await service.warmUpEncoder(audioFileURL: fixtures, modelURL: modelURL, configuration: configuration)
        await service.unloadModel()
    }

    func testSpokenEndingsQuietSpeechPausesAndVocabulary() async throws {
        let (model, modelURL) = try await verifiedModel()
        let cases: [(filename: String, expected: String)] = [
            ("thank-you-en.wav", "thank you"),
            ("look-en.wav", "look"),
            ("quiet-en.wav", "please send the report tomorrow"),
            ("pauses-en.wav", "please send the report tomorrow"),
            ("speech-id.wav", "tolong kirim")
        ]
        // Require the whole matrix so an incomplete fixture set does not appear to pass.
        for testCase in cases { _ = try fixtureURL(testCase.filename) }
        let service = WhisperCPPService()
        for testCase in cases {
            var configuration = WhisperConfiguration.default
            configuration.model = model
            configuration.customVocabulary = ["report", "tomorrow"]
            let result = try await service.transcribe(audioFileURL: fixtureURL(testCase.filename),
                modelURL: modelURL, configuration: configuration)
            let words = result.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
            XCTAssertTrue(words.contains(testCase.expected), "\(testCase.filename): \(result.text)")
        }
        await service.unloadModel()
    }

    func testIndonesianTranslationWithLargeV3() async throws {
        let (_, modelURL) = try await verifiedModel(required: .largeV3)
        let audioURL = try fixtureURL("translation-id.wav")
        var configuration = WhisperConfiguration.default
        configuration.model = .largeV3
        configuration.taskMode = .translateToEnglish
        let service = WhisperCPPService()
        let result = try await service.transcribe(audioFileURL: audioURL, modelURL: modelURL, configuration: configuration)
        XCTAssertTrue(result.text.lowercased().contains("report"), result.text)
        XCTAssertEqual(result.detectedLanguageCode, "id")
        await service.unloadModel()
    }

    func testBriefWordsAndNegationWithBase() async throws {
        try await assertBriefWordsAndNegation(model: .base)
    }

    func testBriefWordsAndNegationWithLargeV3Turbo() async throws {
        try await assertBriefWordsAndNegation(model: .largeV3Turbo)
    }

    func testBreathAndRoomNoiseProduceNoTranscript() async throws {
        let (model, modelURL) = try await verifiedModel()
        let audioURL = try fixtureURL("breath.wav")
        var configuration = WhisperConfiguration.default
        configuration.model = model
        let service = WhisperCPPService()
        let result = try await service.transcribe(audioFileURL: audioURL, modelURL: modelURL, configuration: configuration)
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNil(result.detectedLanguageCode)
        await service.unloadModel()
    }

    func testSyntheticRoomNoiseProducesNoTranscript() async throws {
        let (model, modelURL) = try await verifiedModel()
        let audioURL = try fixtureURL("noise.wav")
        var configuration = WhisperConfiguration.default
        configuration.model = model
        let service = WhisperCPPService()
        let result = try await service.transcribe(audioFileURL: audioURL, modelURL: modelURL, configuration: configuration)
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNil(result.detectedLanguageCode)
        await service.unloadModel()
    }

    func testIssue15AffectedRecordingHasNoInventedEnding() async throws {
        let (_, modelURL) = try await verifiedModel(required: .largeV3Turbo)
        let audioURL = try fixtureURL("issue15-31.5s.m4a")
        var configuration = WhisperConfiguration.default
        configuration.model = .largeV3Turbo
        let service = WhisperCPPService()
        let result = try await service.transcribe(audioFileURL: audioURL, modelURL: modelURL, configuration: configuration)
        XCTAssertTrue(result.text.lowercased().contains("i wrote the test first and the implementation"))
        // This exact recording did not contain these words. Production has no phrase filter.
        XCTAssertFalse(result.text.lowercased().hasSuffix("thank you."))
        assertTimestamps(result, duration: 31.5)
        await service.unloadModel()
    }

    func testIssue15ControlRecordingPreservesSpeech() async throws {
        let (_, modelURL) = try await verifiedModel(required: .largeV3Turbo)
        let audioURL = try fixtureURL("issue15-61.6s.m4a")
        let expectedURL = try fixtureURL("issue15-61.6s.txt")
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(expected.isEmpty)
        var configuration = WhisperConfiguration.default
        configuration.model = .largeV3Turbo
        let service = WhisperCPPService()
        let result = try await service.transcribe(audioFileURL: audioURL, modelURL: modelURL, configuration: configuration)
        XCTAssertEqual(result.text, expected)
        assertTimestamps(result, duration: 61.6)
        await service.unloadModel()
    }

    private func assertBriefWordsAndNegation(model: WhisperModelDescriptor) async throws {
        let (_, modelURL) = try await verifiedModel(required: model)
        let decoder = AVAudioDecodingService()
        let no = try await decoder.decodePCMFloatSamples(from: fixtureURL("brief-no-en.wav"))
        let look = try await decoder.decodePCMFloatSamples(from: fixtureURL("brief-look-en.wav"))
        let sentence = try await decoder.decodePCMFloatSamples(from: fixtureURL("speech-en.wav"))
        // Longer pronunciations passed even with the old 250 ms cutoff.
        for word in [no, look] {
            XCTAssertGreaterThan(word.count, 1_600)
            XCTAssertLessThan(word.count, 4_000, "The spoken word must be shorter than 250 ms")
        }

        let leadingSilence = [Float](repeating: 0, count: 8_000)
        let pause = [Float](repeating: 0, count: 8_000)
        let trailingSilence = [Float](repeating: 0, count: 32_000)
        let cases: [(samples: [Float], expected: String)] = [
            (leadingSilence + no + trailingSilence, "no"),
            (leadingSilence + look + trailingSilence, "look"),
            (leadingSilence + no + pause + sentence + trailingSilence, "no please send the report tomorrow"),
            (leadingSilence + look + pause + sentence + trailingSilence, "look please send the report tomorrow")
        ]
        let configurations: [WhisperConfiguration] = [
            WhisperConfiguration(model: model, inputLanguage: .automatic, taskMode: .transcribe),
            WhisperConfiguration(model: model, inputLanguage: .languageCode("en"), taskMode: .transcribe),
            WhisperConfiguration(model: model, inputLanguage: .automatic, taskMode: .transcribe,
                                 customVocabulary: ["report", "tomorrow"]),
            WhisperConfiguration(model: model, inputLanguage: .languageCode("en"), taskMode: .translateToEnglish)
        ]
        let pcmDecoder = IntegrationPCMDecoder(samples: [])
        let service = WhisperCPPService(audioDecodingService: pcmDecoder)
        for configuration in configurations {
            for testCase in cases {
                await pcmDecoder.setSamples(testCase.samples)
                let result = try await service.transcribe(audioFileURL: fixtures, modelURL: modelURL,
                                                         configuration: configuration)
                let words = result.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                XCTAssertEqual(words, testCase.expected,
                               "\(model.rawValue), \(configuration.inputLanguage), \(configuration.taskMode): \(result.text)")
                assertTimestamps(result, duration: Double(testCase.samples.count) / 16_000)
            }
        }
        // A retained short word must not leak into the next silent recording.
        await pcmDecoder.setSamples(trailingSilence)
        let silence = try await service.transcribe(audioFileURL: fixtures, modelURL: modelURL,
                                                  configuration: configurations[0])
        XCTAssertEqual(silence.text, "")
        XCTAssertTrue(silence.segments.isEmpty)
        XCTAssertNil(silence.detectedLanguageCode)
        await service.unloadModel()
    }

    private func fixtureURL(_ filename: String) throws -> URL {
        let url = fixtures.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Optional Whisper audio fixture is missing: \(filename)")
        }
        return url
    }

    private func verifiedModel(required: WhisperModelDescriptor? = nil) async throws -> (WhisperModelDescriptor, URL) {
        let candidates = required.map { [$0] } ?? [.base, .largeV3Turbo]
        guard let model = candidates.first(where: {
            FileManager.default.fileExists(atPath: fixtures.appendingPathComponent($0.filename).path)
        }) else {
            throw XCTSkip("Pinned Whisper test weights are not installed")
        }
        let downloads = WhisperModelDownloadService(modelsDirectoryURL: fixtures)
        let verifiedURL = await downloads.verifiedWhisperModelURL(for: model)
        return (model, try XCTUnwrap(verifiedURL, "Whisper fixture checksum must match its pinned descriptor"))
    }

    private func assertTimestamps(_ result: WhisperTranscriptionResult, duration: TimeInterval,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var previousStart: TimeInterval = 0
        for segment in result.segments {
            XCTAssertGreaterThanOrEqual(segment.startTime, previousStart, file: file, line: line)
            XCTAssertGreaterThan(segment.endTime, segment.startTime, file: file, line: line)
            XCTAssertLessThanOrEqual(segment.endTime, duration + 0.1, file: file, line: line)
            previousStart = segment.startTime
        }
    }
}

private actor IntegrationPCMDecoder: AudioDecodingServiceProtocol {
    private var samples: [Float]
    init(samples: [Float]) { self.samples = samples }
    func setSamples(_ samples: [Float]) { self.samples = samples }
    func decodePCMFloatSamples(from fileURL: URL) async throws -> [Float] { samples }
}
