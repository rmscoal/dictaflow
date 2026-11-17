import XCTest
@testable import DictaFlow_Dev

/// The speech picker groups models by provider (OpenAI / Liquid) and the
/// recognition engine follows the selected group. Users never pick an engine.
final class SpeechRecognitionProviderTests: XCTestCase {
    func testSpeechModelNameFollowsProvider() {
        var configuration = WhisperConfiguration.default
        configuration.recognitionProvider = .whisper
        XCTAssertEqual(configuration.speechModelName, "Whisper \(configuration.model.displayName)")

        configuration.recognitionProvider = .liquid
        XCTAssertEqual(configuration.speechModelName, "Liquid LFM3-Audio-2B")
    }

    func testSpeechProviderPickerMetadata() {
        XCTAssertEqual(SpeechRecognitionProvider.whisper.compactTitle, "OpenAI")
        XCTAssertEqual(SpeechRecognitionProvider.liquid.compactTitle, "Liquid")
        XCTAssertEqual(SpeechRecognitionProvider.whisper.iconName, "provider-openai")
        XCTAssertEqual(SpeechRecognitionProvider.liquid.iconName, "provider-liquid")
    }

    func testLegacyConfigurationsWithoutProviderDecodeAsWhisper() throws {
        var encoded = try JSONEncoder().encode(WhisperConfiguration.default)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "recognitionProvider")
        encoded = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(WhisperConfiguration.self, from: encoded)
        XCTAssertEqual(decoded.recognitionProvider, .whisper)
        XCTAssertTrue(decoded.speechModelName.hasPrefix("Whisper "))
    }
}
