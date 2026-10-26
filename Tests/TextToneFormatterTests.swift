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

    func testCasualRemovesProseCommasAndOnlyDropsTerminalPeriod() {
        XCTAssertEqual(formatted("Hmm, I'm gonna be late. There's a dog.", .casual), "hmm im gonna be late. theres a dog")
        XCTAssertEqual(formatted("I'm late! Are you coming?", .casual), "im late! are you coming?")
        XCTAssertEqual(formatted("Got it, I will use TypeScript. Next, discuss the CLI framework.", .casual),
                       "got it i will use typescript. next discuss the cli framework")
        XCTAssertEqual(formatted("Hello,world.", .casual), "hello world")
        XCTAssertEqual(formatted("Wait, really... Yes!", .casual), "wait really... yes!")
        XCTAssertEqual(formatted("hmm...", .casual), "hmm...")
        XCTAssertEqual(formatted("I'm late.  ", .casual), "im late  ")
        XCTAssertEqual(formatted("First, check this.\nNext, send it.  ", .casual), "first check this.\nnext send it  ")
        XCTAssertEqual(formatted("hello  ", .formal), "Hello.  ")
    }

    func testCasualLowercasesNamesAcronymsAndNonEnglishProse() {
        XCTAssertEqual(formatted("Alice uses NASA and SwiftUI.", .casual), "alice uses nasa and swiftui")
        XCTAssertEqual(formatted("GOT IT, I'M READY.", .casual), "got it im ready")
        XCTAssertEqual(formatted("Kirim, Besok. Kemudian, Periksa Hasilnya.", .casual, english: false),
                       "kirim besok. kemudian periksa hasilnya")
        XCTAssertEqual(formatted("ÉCOLE, Über Alles.", .casual, english: false), "école über alles")
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

    func testProtectedVocabularyAndStructuredText() {
        let text = "I'm meeting Alice at NASA about SwiftUI and foo_bar v2 at 3.14. Use https://Example.com/Path or Bob@Example.com and `I'm SwiftUI`."
        let output = formatted(text, .casual, terms: ["meeting"])
        XCTAssertEqual(output, "im meeting alice at nasa about swiftui and foo_bar v2 at 3.14. use https://Example.com/Path or Bob@Example.com and `I'm SwiftUI`")
        XCTAssertEqual(formatted("I'm late", .casual, terms: ["I'm"]), "I'm late")
        XCTAssertEqual(formatted("Use DictaFlow, Please.", .casual, terms: ["DictaFlow"]), "use DictaFlow please")
        XCTAssertEqual(formatted("Keep Hello, World.", .casual, terms: ["Hello, World"]), "keep Hello, World")
        XCTAssertEqual(formatted("Use https://Example.com/A,B and `Hello, World`. Done.", .casual),
                       "use https://Example.com/A,B and `Hello, World`. done")
        XCTAssertEqual(formatted("Use User_ID and Module.Name, Please.", .casual), "use User_ID and Module.Name please")
        XCTAssertEqual(formatted("Cost 1,234.56, Or 1.234,56. Then 12,5.", .casual), "cost 1,234.56 or 1.234,56. then 12,5")
        XCTAssertEqual(formatted("```swift\nlet Name = \"Hi, World.\"\n```\nDone, Thanks.", .casual),
                       "```swift\nlet Name = \"Hi, World.\"\n```\ndone thanks")
        XCTAssertEqual(formatted("`I'm gonna", .formal), "`I'm gonna")
        XCTAssertEqual(formatted("https://example.com", .formal), "https://example.com")
        XCTAssertEqual(formatted("version 3.14", .formal), "Version 3.14")
        XCTAssertEqual(formatted("HTTPS://Example.com/path", .formal), "HTTPS://Example.com/path")
        XCTAssertEqual(formatted("foo.bar", .formal), "foo.bar")
        XCTAssertEqual(formatted("IT is ready", .casual), "it is ready")
        XCTAssertEqual(formatted("UM is a name", .formal), "UM is a name.")
        XCTAssertEqual(formatted("uh huh", .formal), "uh huh")
    }

    func testCasualPreservesNumericSeparatorsWithAttachedUnits() {
        let quantities = [
            "1,234kg", "1,234.56kg", "12,5kg", "1.234,56kg",
            "1,234MB", "1,234cm2", "-1,234kg", "1,234µg"
        ]
        for quantity in quantities {
            let input = "Weight \(quantity), Please."
            let output = formatted(input, .casual)
            XCTAssertEqual(output, "weight \(quantity) please", input)
            XCTAssertEqual(formatted(output, .casual), output, "Formatting must be idempotent: \(input)")
            XCTAssertEqual(formatted(input, .formal), input)
        }
        XCTAssertEqual(formatted("Berat 12,5kg, Tolong.", .casual, english: false), "berat 12,5kg tolong")
    }

    func testNonEnglishNeverGetsEnglishWordReplacement() {
        XCTAssertEqual(formatted("I'm gonna", .formal, english: false), "I'm gonna.")
        XCTAssertEqual(formatted("I'm gonna", .casual, english: false), "i'm gonna")
    }

    func testRulesAreIdempotent() {
        for tone in TextTone.allCases {
            for text in [
                "Hmm, um, I'm gonna be late. There's a dog.", "hmm...", "`I'm gonna`",
                "Hello Alice", "", "hello\nworld", "Hello,world.", "Cost 1,234.56, Please.",
                "First, Wait.\nNext, Go.", "Use `Hello, World`. Done."
            ] {
                let once = formatted(text, tone)
                XCTAssertEqual(formatted(once, tone), once, "\(tone): \(text)")
            }
        }
    }

    func testVersionOneCasualSnapshotKeepsItsSavedText() throws {
        var result = WhisperTranscriptionResult(text: "Got it, I'm late.", segments: [], detectedLanguageCode: "en", model: .base, taskMode: .transcribe, completedAt: Date())
        result.toneFormatting = ToneFormattingResult(tone: .casual, formatterVersion: 1, text: "Got it, im late")
        let saved = try JSONDecoder().decode(WhisperTranscriptionResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(saved.insertionText, "Got it, im late")
        XCTAssertEqual(saved.toneFormatting?.formatterVersion, 1)
        let current = TextToneFormatter.format(result.text, tone: .casual, isEnglish: true)
        XCTAssertEqual(current.text, "got it im late")
        XCTAssertEqual(current.formatterVersion, 2)
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
