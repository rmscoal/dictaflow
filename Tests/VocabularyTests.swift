import Foundation
import XCTest
@testable import DictaFlow_Dev

final class VocabularyTests: XCTestCase {
    private func rule(_ trigger: String, _ replacement: String) -> VocabularyReplacementRule {
        VocabularyReplacementRule(trigger: trigger, replacement: replacement, entryID: UUID())
    }

    private func apply(_ text: String, _ rules: [VocabularyReplacementRule]) -> String {
        TextReplacementProcessor.apply(text, rules: rules).text
    }

    // MARK: Matcher contract

    func testExactPhraseCaseVariantsAndSavedCasing() {
        let rules = [rule("dicta flow", "DictaFlow")]
        XCTAssertEqual(apply("Send the dicta flow update.", rules), "Send the DictaFlow update.")
        XCTAssertEqual(apply("Send the Dicta Flow update.", rules), "Send the DictaFlow update.")
        XCTAssertEqual(apply("Send the DICTA FLOW update.", rules), "Send the DictaFlow update.")
        XCTAssertEqual(apply("dictaflow is here", [rule("dictaflow", "DictaFlow")]), "DictaFlow is here")
    }

    func testNoSubstringMatchesAndPunctuationRetained() {
        let rules = [rule("cat", "dog")]
        XCTAssertEqual(apply("A cat, cats and concatenate.", rules), "A dog, cats and concatenate.")
        XCTAssertEqual(apply("my_cat and cat1 stay", rules), "my_cat and cat1 stay")
        XCTAssertEqual(apply("(cat)!", rules), "(dog)!")
    }

    func testApostrophesHyphensAndDiacritics() {
        XCTAssertEqual(apply("I can't go", [rule("can", "will")]), "I can't go")
        XCTAssertEqual(apply("I can’t go", [rule("can", "will")]), "I can’t go")
        XCTAssertEqual(apply("I can go", [rule("can", "will")]), "I will go")
        XCTAssertEqual(apply("well-known fact", [rule("known", "famous")]), "well-famous fact")
        XCTAssertEqual(apply("Use café now", [rule("cafe", "shop")]), "Use café now")
        XCTAssertEqual(apply("Use café now", [rule("café", "shop")]), "Use shop now")
        XCTAssertEqual(apply("CAFÉ time", [rule("café", "shop")]), "shop time")
    }

    func testLongestOverlapLeftToRightAndNonCascading() {
        let rules = [rule("new york", "NYC"), rule("new york city", "New York City")]
        XCTAssertEqual(apply("in new york city today", rules), "in New York City today")
        XCTAssertEqual(apply("in new york today", rules), "in NYC today")
        let chain = [rule("a", "B"), rule("b", "C")]
        XCTAssertEqual(apply("a", chain), "B")
        XCTAssertEqual(apply("a b", chain), "B C")
    }

    func testLiteralMetacharactersSpacesAndEmptyInputs() {
        XCTAssertEqual(apply("Price is 1.5x now", [rule("1.5x", "fast")]), "Price is fast now")
        XCTAssertEqual(apply("Use c++ here", [rule("c++", "C plus plus")]), "Use C plus plus here")
        XCTAssertEqual(apply("dicta  flow here", [rule("dicta flow", "DictaFlow")]), "dicta  flow here")
        XCTAssertEqual(apply("", [rule("a", "B")]), "")
        XCTAssertEqual(apply("hello", []), "hello")
        let output = TextReplacementProcessor.apply("cloud and cloud", rules: [rule("cloud", "Claude")])
        XCTAssertEqual(output.text, "Claude and Claude")
        XCTAssertEqual(output.appliedSpellings, ["cloud"])
    }

    func testMixedLanguageAndDisabledRulesExcludedByConstruction() {
        let settings = VocabularySettings(entries: [
            VocabularyEntry(text: "DictaFlow", replacementSpellings: ["dicta flow"], isEnabled: true),
            VocabularyEntry(text: "Meranti", replacementSpellings: ["meranti"], isEnabled: false)
        ])
        XCTAssertEqual(settings.enabledTerms, ["DictaFlow"])
        XCTAssertEqual(apply("dicta flow dan meranti", settings.enabledRules), "DictaFlow dan meranti")
    }

    // MARK: Validation

    func testValidationDuplicatesConflictsAndCaseCorrection() {
        var settings = VocabularySettings(entries: [
            VocabularyEntry(text: "DictaFlow", replacementSpellings: ["dicta flow"])
        ])
        XCTAssertEqual(settings.validationError(text: " dictaflow ", spellings: []),
                       .duplicateTerm(existing: settings.entries[0]))
        // Case-only correction of its own term is valid.
        XCTAssertNil(settings.validationError(text: "DictaFlow", spellings: ["dictaflow"], editingID: settings.entries[0].id))
        let owner = settings.entries[0]
        XCTAssertEqual(settings.validationError(text: "Other", spellings: ["Dicta Flow"]),
                       .spellingConflict(spelling: "Dicta Flow", owner: owner))
        XCTAssertEqual(settings.validationError(text: "Other", spellings: ["x", "X"]),
                       .duplicateSpellingWithinEntry)
        XCTAssertEqual(settings.validationError(text: "  ", spellings: []), .emptyTerm)
        XCTAssertEqual(settings.validationError(text: "New", spellings: [], isFromHistory: true), .missingSpelling)
        settings.entries.append(VocabularyEntry(text: "Off", replacementSpellings: ["of"], isEnabled: false))
        XCTAssertNotNil(settings.validationError(text: "New", spellings: ["of"]))
    }

    func testHistoryCorrectionCannotExceedEntryLimitButCanMerge() {
        let settings = VocabularySettings(entries: (1...VocabularySettings.maxEntries).map { VocabularyEntry(text: "Term \($0)") })
        XCTAssertEqual(settings.entries.count, VocabularySettings.maxEntries)
        XCTAssertEqual(settings.validationError(text: "New Term", spellings: ["new term"], isFromHistory: true), .limitReached)
        // Merging a spelling into an existing term stays allowed at the limit.
        XCTAssertNil(settings.validationError(text: "Term 1", spellings: ["term one"], isFromHistory: true))
    }

    // MARK: Persistence and migration

    func testLegacyMigrationAndRoundTrip() throws {
        let name = "VocabularyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        var config = WhisperConfiguration.default
        config.customVocabulary = ["DictaFlow", "Project Meranti"]
        store.saveWhisperConfiguration(config)
        let migrated = store.vocabularySettings
        XCTAssertEqual(migrated.entries.map(\.text), ["DictaFlow", "Project Meranti"])
        XCTAssertTrue(migrated.entries.allSatisfy { $0.isEnabled && $0.replacementSpellings.isEmpty })
        let entry = VocabularyEntry(text: "Rizky Pratama", replacementSpellings: ["risk key pratama"], isEnabled: false)
        store.saveVocabularySettings(VocabularySettings(entries: [entry]))
        XCTAssertEqual(store.vocabularySettings.entries, [entry])
        // Legacy whisper data stays readable for recovery.
        XCTAssertEqual(store.whisperConfiguration.customVocabulary, ["DictaFlow", "Project Meranti"])
    }

    func testCorruptVocabularyDataFallsBackWithoutOverwriting() throws {
        let name = "VocabularyCorrupt.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("not json".utf8), forKey: "vocabulary.settings")
        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertEqual(store.vocabularySettings.entries, [])
        XCTAssertEqual(defaults.data(forKey: "vocabulary.settings"), Data("not json".utf8))
    }

    func testPhraseAwareWhisperValidation() {
        let validation = WhisperConfiguration.validateCustomVocabulary("DictaFlow, Project Meranti\nRizky Pratama")
        XCTAssertEqual(validation.terms, ["DictaFlow", "Project Meranti", "Rizky Pratama"])
        var config = WhisperConfiguration.default
        config.customVocabulary = ["Project Meranti", "project meranti", "  DictaFlow  ", "bad\nterm"]
        let decoded = try? JSONDecoder().decode(WhisperConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded?.customVocabulary, ["Project Meranti", "DictaFlow"])
    }

    func testPromptBudgetKeepsWholeTermsInOrder() {
        let counts: (String) -> Int = { $0.split(separator: " ").count }
        let result = VocabularyPromptBudget.includedTerms(terms: ["one two", "three", "four five six"], tokenCount: counts, budget: 4)
        XCTAssertEqual(result.included, ["one two", "three"])
        XCTAssertEqual(result.excluded, ["four five six"])
    }

    func testReplacementMetadataDecodesAsAbsentForLegacyResults() throws {
        let raw = WhisperTranscriptionResult(text: "dicta flow", segments: [], detectedLanguageCode: "en", model: .base, taskMode: .transcribe, completedAt: Date())
        let decoded = try JSONDecoder().decode(WhisperTranscriptionResult.self, from: JSONEncoder().encode(raw))
        XCTAssertNil(decoded.vocabularyReplacement)
        XCTAssertEqual(decoded.insertionText, "dicta flow")
        var withReplacement = raw
        withReplacement.vocabularyReplacement = VocabularyReplacementResult(text: "DictaFlow", appliedSpellings: ["dicta flow"])
        XCTAssertEqual(withReplacement.insertionText, "DictaFlow")
        let roundTripped = try JSONDecoder().decode(WhisperTranscriptionResult.self, from: JSONEncoder().encode(withReplacement))
        XCTAssertEqual(roundTripped.vocabularyReplacement?.appliedSpellings, ["dicta flow"])
    }
}
