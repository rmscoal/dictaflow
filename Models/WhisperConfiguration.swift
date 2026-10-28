import Foundation

nonisolated struct WhisperConfiguration: Codable, Equatable {
    var model: WhisperModelDescriptor
    var inputLanguage: WhisperInputLanguage
    var taskMode: WhisperTaskMode
    var customVocabulary: [String]

    static let `default` = WhisperConfiguration(
        model: .recommendedDefault,
        inputLanguage: .automatic,
        taskMode: .transcribe,
        customVocabulary: []
    )

    /// Keywords passed to whisper.cpp as `initial_prompt` to bias decoding
    /// toward user terms such as product names or tech jargon.
    /// Returns nil when no usable keywords are present.
    var initialPrompt: String? {
        let terms = customVocabulary.prefix(Self.maxCustomVocabularyTerms)
        guard !terms.isEmpty else {
            return nil
        }
        return terms.joined(separator: ", ")
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case inputLanguage
        case taskMode
        case customVocabulary
    }

    init(
        model: WhisperModelDescriptor,
        inputLanguage: WhisperInputLanguage,
        taskMode: WhisperTaskMode,
        customVocabulary: [String] = []
    ) {
        self.model = model
        self.inputLanguage = inputLanguage
        self.taskMode = taskMode
        self.customVocabulary = customVocabulary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(WhisperModelDescriptor.self, forKey: .model)
        inputLanguage = try container.decode(WhisperInputLanguage.self, forKey: .inputLanguage)
        taskMode = try container.decode(WhisperTaskMode.self, forKey: .taskMode)
        if let storedTerms = try? container.decode([String].self, forKey: .customVocabulary) {
            customVocabulary = Self.sanitizedKeywords(storedTerms)
        } else if let legacyText = try? container.decode(String.self, forKey: .customVocabulary) {
            customVocabulary = Self.validateCustomVocabulary(legacyText).terms
        } else {
            customVocabulary = []
        }
    }

    static func validateCustomVocabulary(_ vocabulary: String) -> CustomVocabularyValidation {
        var seen = Set<String>()
        var terms: [String] = []
        var multiWordEntryCount = 0
        var overflowEntryCount = 0
        var totalValidCount = 0

        // Comma/newline parsing exists only for legacy migration; phrases
        // themselves may contain spaces.
        let entries = vocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for entry in entries {
            guard VocabularySettings.isValidTerm(entry) else { continue }
            if entry.rangeOfCharacter(from: .whitespaces) != nil {
                multiWordEntryCount += 1
            }
            let key = VocabularySettings.normalizedKey(entry)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            totalValidCount += 1
            if terms.count < maxCustomVocabularyTerms {
                terms.append(entry)
            } else {
                overflowEntryCount += 1
            }
        }

        return CustomVocabularyValidation(
            terms: terms,
            multiWordEntryCount: multiWordEntryCount,
            overflowEntryCount: overflowEntryCount,
            totalValidCount: totalValidCount
        )
    }

    private static func sanitizedKeywords(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard VocabularySettings.isValidTerm(cleaned) else { continue }
            let key = VocabularySettings.normalizedKey(cleaned)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(cleaned)
            if result.count == maxCustomVocabularyTerms { break }
        }
        return result
    }

    // Entry ceiling for the library; the actual Whisper prompt is budgeted
    // by token count at the model boundary.
    static let maxCustomVocabularyTerms = 50
}

enum CustomVocabularyKeywordError: Equatable {
    case duplicate
    case limitReached

    var message: String {
        switch self {
        case .duplicate:
            return "That word or phrase is already in your vocabulary."
        case .limitReached:
            return "You already have 50 vocabulary entries. Remove one to add another."
        }
    }
}

nonisolated struct CustomVocabularyValidation: Equatable {
    let terms: [String]
    let multiWordEntryCount: Int
    let overflowEntryCount: Int
    let totalValidCount: Int

    var hasMultiWordEntries: Bool {
        multiWordEntryCount > 0
    }

    var isOverLimit: Bool {
        overflowEntryCount > 0
    }
}
