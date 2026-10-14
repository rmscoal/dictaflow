import XCTest
@testable import DictaFlow_Dev

final class TextToneFormatterTests: XCTestCase {
    private func formatted(_ text: String, _ tone: TextTone, english: Bool = true, terms: [String] = []) -> String {
        TextToneFormatter.format(text, tone: tone, isEnglish: english, protectedTerms: terms).text
    }

    func testOriginalAndBalancedLeaveTextUnchanged() {
        let text = "Hmm, I'm gonna be late.\n  There's a dog. "
        XCTAssertEqual(formatted(text, .original), text)
        XCTAssertEqual(formatted(text, .balanced), text)
        XCTAssertEqual(formatted("", .formal), "")
        XCTAssertEqual(formatted(" \n", .casual), " \n")
    }

    func testCasualKeepsSentencePunctuationAndOnlyDropsTerminalPeriod() {
        XCTAssertEqual(formatted("Hmm, I'm gonna be late. There's a dog.", .casual), "hmm, im gonna be late. theres a dog")
        XCTAssertEqual(formatted("I'm late! Are you coming?", .casual), "im late! Are you coming?")
        XCTAssertEqual(formatted("hmm...", .casual), "hmm...")
        XCTAssertEqual(formatted("I'm late.  ", .casual), "im late  ")
        XCTAssertEqual(formatted("hello  ", .formal), "Hello.  ")
    }

    func testFormalUsesUnambiguousEnglishRules() {
        XCTAssertEqual(formatted("Hmm, I'm gonna be late. There's a dog. I can't walk past him", .formal),
                       "I am going to be late. There is a dog. I cannot walk past him.")
        XCTAssertEqual(formatted("I'd say he's ready. There's been a delay.", .formal), "I'd say he's ready. There's been a delay.")
        XCTAssertEqual(formatted("hmm, um, I can't go", .formal), "I cannot go.")
        XCTAssertEqual(formatted("hmm", .formal, terms: ["hmm"]), "hmm")
        XCTAssertEqual(formatted("hmm, hello. i can't go", .formal), "Hello. I cannot go.")
        XCTAssertEqual(formatted("i'd say he's ready", .formal), "I'd say he's ready.")
    }

    func testProtectedNamesVocabularyAndStructuredText() {
        let text = "I'm meeting Alice at NASA about SwiftUI and foo_bar v2 at 3.14. Use https://Example.com/Path or Bob@Example.com and `I'm SwiftUI`."
        let output = formatted(text, .casual, terms: ["meeting"])
        XCTAssertEqual(output, "im meeting Alice at NASA about SwiftUI and foo_bar v2 at 3.14. Use https://Example.com/Path or Bob@Example.com and `I'm SwiftUI`.")
        XCTAssertEqual(formatted("I'm late", .casual, terms: ["I'm"]), "I'm late")
        XCTAssertEqual(formatted("`I'm gonna", .formal), "`I'm gonna")
        XCTAssertEqual(formatted("https://example.com", .formal), "https://example.com")
        XCTAssertEqual(formatted("version 3.14", .formal), "Version 3.14")
        XCTAssertEqual(formatted("HTTPS://Example.com/path", .formal), "HTTPS://Example.com/path")
        XCTAssertEqual(formatted("foo.bar", .formal), "foo.bar")
        XCTAssertEqual(formatted("IT is ready", .casual), "IT is ready")
        XCTAssertEqual(formatted("UM is a name", .formal), "UM is a name.")
        XCTAssertEqual(formatted("uh huh", .formal), "uh huh")
    }

    func testNonEnglishNeverGetsEnglishWordReplacement() {
        XCTAssertEqual(formatted("I'm gonna", .formal, english: false), "I'm gonna.")
        XCTAssertEqual(formatted("I'm gonna", .casual, english: false), "i'm gonna")
    }

    func testRulesAreIdempotent() {
        for tone in TextTone.allCases {
            for text in ["Hmm, um, I'm gonna be late. There's a dog.", "hmm...", "`I'm gonna`", "Hello Alice", "", "hello\nworld"] {
                let once = formatted(text, tone)
                XCTAssertEqual(formatted(once, tone), once, "\(tone): \(text)")
            }
        }
    }

    func testToneSettingsPersistAndDefaultToOriginal() throws {
        let name = "ToneSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).textTone, .original)
        UserDefaultsSettingsStore(defaults: defaults).saveTextTone(.casual)
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).textTone, .casual)
        defaults.set("future-tone", forKey: "dictation.textTone")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).textTone, .original)
    }

    func testLegacyResultsDecodeAndFinalTextUsesSavedSnapshot() throws {
        let raw = WhisperTranscriptionResult(text: "I'm late.", segments: [], detectedLanguageCode: "en", model: .base, taskMode: .transcribe, completedAt: Date())
        let decoded = try JSONDecoder().decode(WhisperTranscriptionResult.self, from: JSONEncoder().encode(raw))
        XCTAssertNil(decoded.toneFormatting)
        XCTAssertEqual(decoded.insertionText, raw.text)
        var result = raw
        result.toneFormatting = TextToneFormatter.format(raw.text, tone: .casual, isEnglish: true)
        XCTAssertEqual(result.insertionText, "im late")
        result.toneFormatting = ToneFormattingResult(tone: .casual, formatterVersion: 1, text: " im late ")
        XCTAssertEqual(result.insertionText, "im late", "Copy and insertion share outer-whitespace normalization")
        var refined = TranscriptRefinementResult(originalText: raw.text, refinedText: "I'm running late.", model: .qwen3Small, mode: .smartCleanup, completedAt: Date())
        refined.toneFormatting = TextToneFormatter.format(refined.refinedText, tone: .formal, isEnglish: true)
        result.refinement = refined
        XCTAssertEqual(result.insertionText, "I am running late.")
        XCTAssertEqual(result.text, "I'm late.")
        XCTAssertEqual(result.refinement?.refinedText, "I'm running late.")
    }
}
