@testable import AgentVoice
import Foundation
import Testing

struct LiquidSpeechTextTests {
    @Test func tasksKeepTheirStatusAndLiteralMarkersStayLiteral() {
        let input = "- [x] **Review complete.**\n- [X] Build complete.\n- [ ] Run tests.\n- `[x]` is a literal marker.\n\nKeep [x] outside a list."
        #expect(LiquidSpeechText.normalize(input) == "Completed: Review complete.\n\nCompleted: Build complete.\n\nPending: Run tests.\n\n[x] is a literal marker.\n\nKeep [x] outside a list.")
        let continuation = "- First paragraph.\n\n  [x] is a later paragraph in the same item."
        #expect(LiquidSpeechText.normalize(continuation) == "First paragraph.\n\n[x] is a later paragraph in the same item.")
    }

    @Test func htmlFormattingKeepsWordsAndBreaksWithoutDamagingTechnicalNotation() {
        #expect(LiquidSpeechText.normalize("Hello <b>bold</b> and <EM>clear</EM>.") == "Hello bold and clear.")
        #expect(LiquidSpeechText.normalize("First<br/>second<p>Third</p>") == "First\n\nsecond\n\nThird")
        #expect(LiquidSpeechText.normalize("<div>First</div>\n<div>Second</div>") == "First\n\nSecond")
        #expect(LiquidSpeechText.normalize("Hello <b title=\"1 > 0\">reader</b>.") == "Hello reader.")
        let technical = "Keep `Array<String>`, `std::vector<int>`, and `<b>` literal. Keep x < 5 and y > 2, plus Array<T>."
        #expect(LiquidSpeechText.normalize(technical) == "Keep Array<String>, std::vector<int>, and <b> literal. Keep x < 5 and y > 2, plus Array<T>.")
        #expect(LiquidSpeechText.normalize("Keep &lt;b&gt; literal.") == "Keep <b> literal.")
        #expect(LiquidSpeechText.normalize("Keep <b-custom>literal</b-custom>.") == "Keep <b-custom>literal</b-custom>.")
    }

    @Test func looseTableFallbackPreservesSurroundingProseAndPipesInCode() {
        let input = "Before.\n\n| A | B |\n| 1 | 2 |\n\nAfter."
        #expect(LiquidSpeechText.normalize(input) == "Before.\n\n\(LiquidSpeechText.tableNotice)\n\nAfter.")
        for source in ["Run `git diff | head`.", "Keep `ready || fallback` unchanged.", "Use a | b.", "| A | B |", "| A | B |\n| 1 | 2 | 3 |", "`| A | B |`\n`| 1 | 2 |`"] {
            #expect(LiquidSpeechText.normalize(source) != LiquidSpeechText.tableNotice)
        }
        #expect(LiquidSpeechText.normalize("Run `git diff | head`.") == "Run git diff | head.")
        #expect(LiquidSpeechText.normalize("Keep `ready || fallback` unchanged.") == "Keep ready || fallback unchanged.")
        #expect(LiquidSpeechText.normalize("Use a | b.") == "Use a | b.")
        #expect(LiquidSpeechText.normalize("Keep ready || fallback unchanged.") == "Keep ready || fallback unchanged.")
    }

    @Test func foreignAndMixedPlansCannotBypassThePreviewBudget() throws {
        let frenchSentence = "Bonjour, cette application conserve les données sur votre ordinateur. Vous pouvez arrêter la lecture à tout moment."
        let french = Array(repeating: frenchSentence, count: 35).joined(separator: "\n\n")
        let english = Array(repeating: LiquidSpeechTests.historicalReview, count: 3).joined(separator: "\n\n")
        let mixedPrefix = "The local voice test is complete.\n\nMerci beaucoup.\n\n" + english
        let chinese = String(repeating: "这是一个本地语音测试，内容保留在书面回答中。", count: 35)
        for source in [french, english + "\n\nMerci beaucoup.", mixedPrefix, chinese] {
            let chunks = try LiquidSpeechPlan.make(source).chunks
            let spoken = chunks.map(\.text).joined(separator: "\n\n")
            #expect(chunks.first?.text == LiquidSpeechPlan.previewNotice && chunks.first?.language == "en")
            #expect(chunks.count > 1 && chunks.count <= LiquidSpeechPlan.maximumChunks)
            #expect(spoken.count <= LiquidSpeechPlan.maximumCharacters)
            #expect(words(spoken).count <= LiquidSpeechPlan.maximumWords)
        }
        let frenchChunks = try LiquidSpeechPlan.make(french).chunks
        #expect(frenchChunks.dropFirst().allSatisfy { $0.language == "fr" })
        #expect(frenchChunks.dropFirst().map(\.text).joined(separator: " ").hasPrefix(frenchSentence))
        let mixedChunks = try LiquidSpeechPlan.make(mixedPrefix).chunks
        #expect(mixedChunks.contains { $0.text == "Merci beaucoup." && $0.language == "fr" })
        #expect(try LiquidSpeechPlan.make(chinese).chunks.dropFirst().allSatisfy { $0.language == "zh" })
    }

    @Test func shortUnsupportedSentenceDoesNotInheritEnglish() {
        struct Recognizer: LiquidLanguageRecognizing {
            func hypotheses(for text: String) -> [String: Double] {
                text == "Selamat pagi." ? ["id": 0.99] : ["en": 0.99]
            }
        }
        #expect(throws: VoiceError.self) {
            try LiquidSpeechPlan.make("The speech test is complete.\n\nSelamat pagi.", recognizer: Recognizer())
        }
    }

    @Test func multilingualIdentifierUsesTheParagraphLimit() throws {
        struct Recognizer: LiquidLanguageRecognizing {
            func hypotheses(for text: String) -> [String: Double] { ["fr": 0.99] }
        }
        let identifier = String(repeating: "x", count: 180)
        let chunks = try LiquidSpeechPlan.make("Le résultat est prêt. Utilisez `\(identifier)`.", recognizer: Recognizer()).chunks
        #expect(chunks.contains { $0.text.contains(LiquidSpeechText.identifierNotice) })
        #expect(chunks.allSatisfy { $0.language == "fr" && $0.text.count <= 160 })
    }

    @Test func oneWordTermsKeepTheExistingEnglishContextFallback() throws {
        let text = "The local voice test is complete. Your recording controls remain unchanged.\n\nRebase.\n\nDanke.\n\nGracias."
        #expect(try LiquidSpeechPlan.make(text).chunks.allSatisfy { $0.language == "en" })
    }

    @Test func markdownKeepsProseLabelsAndListBoundaries() {
        let input = """
        # Result

        The **result** is *ready*. Read [the guide](https://example.com/guide?q=private).

        - Check the diff.
        - Open `LiquidSpeechPlan.swift`.

        ![Architecture diagram](https://example.com/diagram.png)
        """
        #expect(LiquidSpeechText.normalize(input) == "Result\n\nThe result is ready. Read the guide.\n\nCheck the diff.\n\nOpen LiquidSpeechPlan.swift.\n\nArchitecture diagram")
    }

    @Test func inlineCodeNamesVersionsAndLiteralPunctuationSurvive() {
        let text = "Use `git diff --check`, `Sources/Voice/Plan.swift`, and `2 * 3`. Keep C++, snake_case, version 1.5, #123, and x * y."
        #expect(LiquidSpeechText.normalize(text) == "Use git diff --check, Sources/Voice/Plan.swift, and 2 * 3. Keep C++, snake_case, version 1.5, #123, and x * y.")
        #expect(LiquidSpeechText.normalize("A literal \\* stays.") == "A literal * stays.")
    }

    @Test func webLinksUseHostnamesWithoutPathsQueriesOrCredentials() {
        let text = "✅ Read https://user:password@example.com/a?q=private#section, then http://localhost:8080/docs."
        #expect(LiquidSpeechText.normalize(text) == "✅ Read example.com, then localhost port 8080.")
        #expect(LiquidSpeechText.normalize("Visit <https://example.com/long/path?q=private>.") == "Visit example.com.")
    }

    @Test func codeBlocksAndTablesGetReferencesWithoutInventingASummary() {
        let input = """
        The command is shown below.

        ```swift
        let value = 42
        print(value)
        ```

            git diff --check

        | Model | Result |
        | --- | --- |
        | Liquid | Ready |

        The next step is manual verification.
        """
        let normalized = LiquidSpeechText.normalize(input)
        #expect(normalized == "The command is shown below.\n\n\(LiquidSpeechText.codeNotice)\n\n\(LiquidSpeechText.codeNotice)\n\n\(LiquidSpeechText.tableNotice)\n\nThe next step is manual verification.")
        #expect(!normalized.contains("print") && !normalized.contains("42"))
        #expect(LiquidSpeechText.normalize("```sh\ngit diff --check\n```") == LiquidSpeechText.codeNotice)
        #expect(LiquidSpeechText.normalize("```sh\ngit diff --check") == LiquidSpeechText.codeNotice)
    }

    @Test func longIdentifiersFallBackWithoutDiscardingSurroundingProse() throws {
        let text = "The result is ready. Read " + String(repeating: "x", count: 400) + ". Keep the final caveat."
        let normalized = LiquidSpeechText.normalize(text)
        #expect(normalized == "The result is ready. Read \(LiquidSpeechText.identifierNotice). Keep the final caveat.")
        let plan = try LiquidSpeechPlan.make(text)
        #expect(plan.chunks.map(\.text).joined(separator: " ") == normalized)
        let unspaced = String(repeating: "这是一个测试", count: 80)
        #expect(LiquidSpeechText.normalize(unspaced) == unspaced)
    }

    @Test func formattingOnlyInputStillHasASpokenFallbackAndCleanupIsIdempotent() {
        #expect(LiquidSpeechText.normalize("***") == LiquidSpeechText.emptyNotice)
        #expect(LiquidSpeechText.normalize("First.\n\n---\n\nSecond.") == "First.\n\nSecond.")
        let input = "# Result\n\nRead **the guide** at https://example.com/a?q=private.\n\n```sh\ngit diff\n```"
        let normalized = LiquidSpeechText.normalize(input)
        #expect(LiquidSpeechText.normalize(normalized) == normalized)
    }

    @Test func longEnglishResponseIsAnAnnouncedBoundedPrefix() throws {
        let source = Array(repeating: LiquidSpeechTests.historicalReview, count: 3).joined(separator: "\n\n")
        let chunks = try LiquidSpeechPlan.make(source).chunks
        #expect(chunks.first?.text == LiquidSpeechPlan.previewNotice)
        #expect(chunks.count > 1 && chunks.count <= LiquidSpeechPlan.maximumChunks)
        let spoken = chunks.map(\.text).joined(separator: "\n\n")
        #expect(spoken.count <= LiquidSpeechPlan.maximumCharacters)
        #expect(words(spoken).count <= LiquidSpeechPlan.maximumWords)
        let body = words(chunks.dropFirst().map(\.text).joined(separator: " "))
        #expect(body == Array(words(source).prefix(body.count)), "Preview keeps a continuous prefix, including caveats within its selected chunks.")
        #expect(chunks.last?.text.last == ".", "Stop at a complete planned chunk.")
    }

    @Test func previewsAlsoBoundManyTinyParagraphsAndLongWords() throws {
        let paragraphs = (1...30).map { "Result \($0) is ready." }.joined(separator: "\n\n")
        let dense = Array(repeating: "Verification remains incomplete and requires independent confirmation.", count: 30).joined(separator: " ")
        for source in [paragraphs, dense] {
            let chunks = try LiquidSpeechPlan.make(source).chunks
            #expect(chunks.first?.text == LiquidSpeechPlan.previewNotice)
            #expect(chunks.count <= LiquidSpeechPlan.maximumChunks)
            #expect(chunks.map(\.text).joined(separator: "\n\n").count <= LiquidSpeechPlan.maximumCharacters)
        }
    }

    @Test func clearSupportedShortPhraseOverridesEnglishButHeadingsKeepContext() throws {
        let text = "The local voice test is complete. Your recording controls remain unchanged.\n\nModels\n\nSpeech\n\nPlay\n\nMerci beaucoup."
        let chunks = try LiquidSpeechPlan.make(text).chunks
        #expect(chunks.map(\.language) == ["en", "en", "en", "en", "fr"])
    }

    private func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
}
