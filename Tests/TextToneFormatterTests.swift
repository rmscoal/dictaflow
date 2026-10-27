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
        XCTAssertEqual(formatted("Hmm, I'm gonna be late. There's a dog.", .casual), "hmm i'm gonna be late. there's a dog")
        XCTAssertEqual(formatted("I'm late! Are you coming?", .casual), "i'm late! are you coming?")
        XCTAssertEqual(formatted("Got it, I will use TypeScript. Next, discuss the CLI framework.", .casual),
                       "got it i will use typescript. next discuss the cli framework")
        XCTAssertEqual(formatted("Hello,world.", .casual), "hello world")
        XCTAssertEqual(formatted("Wait, really... Yes!", .casual), "wait really... yes!")
        XCTAssertEqual(formatted("hmm...", .casual), "hmm...")
        XCTAssertEqual(formatted("I'm late.  ", .casual), "i'm late  ")
        XCTAssertEqual(formatted("First, check this.\nNext, send it.  ", .casual), "first check this.\nnext send it  ")
        XCTAssertEqual(formatted("hello  ", .formal), "Hello.  ")
    }

    func testCasualLowercasesNamesAcronymsAndNonEnglishProse() {
        XCTAssertEqual(formatted("Alice uses NASA and SwiftUI.", .casual), "alice uses nasa and swiftui")
        XCTAssertEqual(formatted("GOT IT, I'M READY.", .casual), "got it i'm ready")
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
        XCTAssertEqual(output, "i'm meeting alice at nasa about swiftui and foo_bar v2 at 3.14. use https://Example.com/Path or Bob@Example.com and `I'm SwiftUI`")
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

    func testCasualPreservesContractionApostrophes() {
        // Issue #33: removing the apostrophe changes the word (we're -> were).
        XCTAssertEqual(formatted("Sometimes we're connected to the laptop.", .casual),
                       "sometimes we're connected to the laptop")
        XCTAssertEqual(formatted("Sometimes we’re connected to the laptop.", .casual),
                       "sometimes we’re connected to the laptop")
        XCTAssertEqual(formatted("We'll check whether it's ready.", .casual),
                       "we'll check whether it's ready")
        XCTAssertEqual(formatted("I'll go, but don't wait.", .casual), "i'll go but don't wait")
        // Every contraction in the Formal expansion dictionary keeps its apostrophe.
        XCTAssertEqual(formatted("I'm here. You're here. They're here.", .casual),
                       "i'm here. you're here. they're here")
        XCTAssertEqual(formatted("I've seen it. You've seen it. We've seen it. They've seen it.", .casual),
                       "i've seen it. you've seen it. we've seen it. they've seen it")
        XCTAssertEqual(formatted("You'll see. They'll see.", .casual), "you'll see. they'll see")
        XCTAssertEqual(formatted("I can't go. He won't go. Don't wait.", .casual),
                       "i can't go. he won't go. don't wait")
        XCTAssertEqual(formatted("It doesn't work. It didn't work. It isn't ready. They aren't ready.", .casual),
                       "it doesn't work. it didn't work. it isn't ready. they aren't ready")
        XCTAssertEqual(formatted("It wasn't ready. They weren't ready. I haven't seen it. He hasn't seen it.", .casual),
                       "it wasn't ready. they weren't ready. i haven't seen it. he hasn't seen it")
        XCTAssertEqual(formatted("There's a dog.", .casual), "there's a dog")
        XCTAssertEqual(formatted("I'm gonna go.", .casual), "i'm gonna go")
        // Contractions absent from the dictionary were already preserved; keep them that way.
        XCTAssertEqual(formatted("It's ready. She'd go. He'll go. We'd go. Let's go.", .casual),
                       "it's ready. she'd go. he'll go. we'd go. let's go")
        XCTAssertEqual(formatted("She'll go. Could've gone. Shouldn't go. Y'all ready. That's it. O'clock sharp.", .casual),
                       "she'll go. could've gone. shouldn't go. y'all ready. that's it. o'clock sharp")
        // Words already missing apostrophes are never "corrected" by guessing.
        XCTAssertEqual(formatted("Were well ill.", .casual), "were well ill")
        // Possessives, names, and all-caps contractions keep their apostrophes.
        XCTAssertEqual(formatted("Alice's bag is ready.", .casual), "alice's bag is ready")
        XCTAssertEqual(formatted("O'Brien is ready.", .casual), "o'brien is ready")
        XCTAssertEqual(formatted("WE'RE READY, DON'T GO.", .casual), "we're ready don't go")
        // Contractions next to Casual punctuation rules and inside protected text.
        XCTAssertEqual(formatted("I think we're.", .casual), "i think we're")
        XCTAssertEqual(formatted("We're... ready!", .casual), "we're... ready!")
        XCTAssertEqual(formatted("Use `we're` here, please.", .casual), "use `we're` here please")
        // Repeated formatting must be stable.
        for text in ["Sometimes we're connected to the laptop.", "We'll check whether it's ready.",
                     "I'll go, but don't wait.", "WE'RE READY, DON'T GO."] {
            let once = formatted(text, .casual)
            XCTAssertEqual(formatted(once, .casual), once, "Formatting must be idempotent: \(text)")
        }
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
        XCTAssertEqual(current.text, "got it i'm late")
        XCTAssertEqual(current.formatterVersion, 3)
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

    func testFinalFormattingSliderMapping() {
        XCTAssertEqual(TextTone.casual.finalFormattingPosition, 0)
        XCTAssertEqual(TextTone.original.finalFormattingPosition, 1)
        XCTAssertEqual(TextTone.formal.finalFormattingPosition, 2)
        XCTAssertEqual(TextTone.finalFormattingTone(at: 0), .casual)
        XCTAssertEqual(TextTone.finalFormattingTone(at: 1), .original)
        XCTAssertEqual(TextTone.finalFormattingTone(at: 2), .formal)
        XCTAssertEqual(TextTone.finalFormattingTone(at: -1), .casual)
        XCTAssertEqual(TextTone.finalFormattingTone(at: 3), .formal)
        XCTAssertEqual(TextTone.casual.finalFormattingTitle, "Casual")
        XCTAssertEqual(TextTone.original.finalFormattingTitle, "Original")
        XCTAssertEqual(TextTone.formal.finalFormattingTitle, "Formal")
    }

    func testLegacyBalancedMapsToCenterWithoutRewritingStoredValue() throws {
        XCTAssertEqual(TextTone.balanced.finalFormattingPosition, 1)
        XCTAssertEqual(TextTone.balanced.finalFormattingTitle, "Original")
        let name = "FinalFormattingBalancedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.saveTextTone(.balanced)
        XCTAssertEqual(store.textTone, .balanced)
        // Merely reading the preference must not rewrite the stored value.
        XCTAssertEqual(defaults.string(forKey: "dictation.textTone"), "balanced")
        // The balanced center behaves exactly like Original in the formatter.
        let text = "Hey, I can't ship until we're done."
        XCTAssertEqual(formatted(text, .balanced), formatted(text, .original))
    }

    func testExampleCompositionAppliesRealFormatting() {
        let usableSmartFormal = OutputExampleComposer.output(refinementUsable: true, effectiveMode: .smartCleanup, tone: .formal)
        XCTAssertEqual(usableSmartFormal,
                       "Hey, can you review the auth PR by Wednesday? It might fix the login issue, but we cannot ship until we are done testing.")
        let usableSmartOriginal = OutputExampleComposer.output(refinementUsable: true, effectiveMode: .smartCleanup, tone: .original)
        XCTAssertEqual(usableSmartOriginal, RefinementMode.smartCleanup.writingExample)
        let offFormal = OutputExampleComposer.output(refinementUsable: false, effectiveMode: .smartCleanup, tone: .formal)
        XCTAssertEqual(offFormal,
                       "Hey um can you review the auth PR by Wednesday? I think it might fix the login issue but yeah we cannot ship until we are done testing.")
        let offCasual = OutputExampleComposer.output(refinementUsable: false, effectiveMode: .smartCleanup, tone: .casual)
        XCTAssertEqual(offCasual,
                       "hey um can you review the auth pr by wednesday? i think it might fix the login issue but yeah we can't ship until we're done testing")
        // DIY never pretends to execute custom instructions in the preview.
        let diyFormal = OutputExampleComposer.output(refinementUsable: true, effectiveMode: .diy, tone: .formal)
        XCTAssertEqual(diyFormal, offFormal)
        // Legacy balanced shows the same composed output as Original.
        XCTAssertEqual(OutputExampleComposer.output(refinementUsable: true, effectiveMode: .smartCleanup, tone: .balanced),
                       usableSmartOriginal)
    }

    func testLegacyResultsDecodeAndFinalTextUsesSavedSnapshot() throws {
        let raw = WhisperTranscriptionResult(text: "I'm late.", segments: [], detectedLanguageCode: "en", model: .base, taskMode: .transcribe, completedAt: Date())
        let decoded = try JSONDecoder().decode(WhisperTranscriptionResult.self, from: JSONEncoder().encode(raw))
        XCTAssertNil(decoded.toneFormatting)
        XCTAssertEqual(decoded.insertionText, raw.text)
        var result = raw
        result.toneFormatting = TextToneFormatter.format(raw.text, tone: .casual, isEnglish: true)
        XCTAssertEqual(result.insertionText, "i'm late")
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
