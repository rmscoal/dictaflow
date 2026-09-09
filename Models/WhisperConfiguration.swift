import Foundation

struct WhisperConfiguration: Codable, Equatable {
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

        let entries = vocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for entry in entries {
            if entry.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                multiWordEntryCount += 1
                continue
            }

            let key = entry.lowercased()
            guard !seen.contains(key) else {
                continue
            }
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
            guard !cleaned.isEmpty,
                  cleaned.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !seen.contains(cleaned.lowercased()) else {
                continue
            }
            seen.insert(cleaned.lowercased())
            result.append(cleaned)

            if result.count == maxCustomVocabularyTerms {
                break
            }
        }

        return result
    }

    // whisper.cpp only consumes the last ~224 prompt tokens, so 50 short
    // single-word keywords stay well inside that budget.
    static let maxCustomVocabularyTerms = 50
}

enum CustomVocabularyKeywordError: Equatable {
    case multiWord
    case duplicate
    case limitReached

    var message: String {
        switch self {
        case .multiWord:
            return "Use single words only. Entries with spaces are not added."
        case .duplicate:
            return "That keyword is already in your vocabulary."
        case .limitReached:
            return "You already have 50 keywords. Remove one to add another."
        }
    }
}

struct CustomVocabularyValidation: Equatable {
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
