import Foundation

nonisolated struct VocabularyEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var replacementSpellings: [String]
    var isEnabled: Bool

    init(id: UUID = UUID(), text: String, replacementSpellings: [String] = [], isEnabled: Bool = true) {
        self.id = id
        self.text = text
        self.replacementSpellings = replacementSpellings
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case id, text, replacementSpellings, isEnabled }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        replacementSpellings = try container.decodeIfPresent([String].self, forKey: .replacementSpellings) ?? []
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

nonisolated struct VocabularyReplacementRule: Equatable {
    let trigger: String
    let replacement: String
    let entryID: UUID
}

nonisolated struct VocabularySettings: Codable, Equatable {
    var version: Int
    var entries: [VocabularyEntry]

    static let currentVersion = 1
    static let maxEntries = 50
    static let empty = VocabularySettings(entries: [])

    init(version: Int = currentVersion, entries: [VocabularyEntry] = []) {
        self.version = version
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case version, entries }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        entries = try container.decodeIfPresent([VocabularyEntry].self, forKey: .entries) ?? []
    }

    var enabledTerms: [String] { entries.filter(\.isEnabled).map(\.text) }

    var enabledRules: [VocabularyReplacementRule] {
        entries.filter(\.isEnabled).flatMap { entry in
            entry.replacementSpellings.map { VocabularyReplacementRule(trigger: $0, replacement: entry.text, entryID: entry.id) }
        }
    }

    static func migrated(fromLegacyTerms terms: [String]) -> VocabularySettings {
        var seen = Set<String>()
        var entries: [VocabularyEntry] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidTerm(term) else { continue }
            let key = normalizedKey(term)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            entries.append(VocabularyEntry(text: term))
            if entries.count == maxEntries { break }
        }
        return VocabularySettings(entries: entries)
    }

    static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    static func isValidTerm(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    func entry(matchingTerm term: String) -> VocabularyEntry? {
        let key = Self.normalizedKey(term)
        return entries.first { Self.normalizedKey($0.text) == key }
    }

    func entryOwningSpelling(_ spelling: String, excludingEntryID: UUID? = nil) -> VocabularyEntry? {
        let key = Self.normalizedKey(spelling)
        return entries.first { entry in
            entry.id != excludingEntryID && entry.replacementSpellings.contains { Self.normalizedKey($0) == key }
        }
    }

    /// Validates a candidate entry. `editingID` is the entry being edited, if any.
    func validationError(text: String, spellings: [String], editingID: UUID? = nil, isFromHistory: Bool = false) -> VocabularyValidationError? {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTerm(term) else { return .emptyTerm }
        if term.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return .invalidTerm
        }
        let cleaned = spellings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for spelling in cleaned where !Self.isValidTerm(spelling) { return .invalidSpelling }
        if let existing = entry(matchingTerm: term), existing.id != editingID, !isFromHistory {
            return .duplicateTerm(existing: existing)
        }
        // Duplicates within the candidate.
        var seen = Set<String>()
        for spelling in cleaned {
            let key = Self.normalizedKey(spelling)
            guard !seen.contains(key) else { return .duplicateSpellingWithinEntry }
            seen.insert(key)
        }
        // A spelling equal to its own term with different case is valid; equal
        // ignoring case to another entry's spelling is a conflict.
        for spelling in cleaned {
            if let owner = entryOwningSpelling(spelling, excludingEntryID: editingID) {
                // When merging from History into the matching term entry, spellings
                // already owned by that same entry are not a conflict.
                if isFromHistory, let target = entry(matchingTerm: term), owner.id == target.id { continue }
                return .spellingConflict(spelling: spelling, owner: owner)
            }
        }
        if isFromHistory && cleaned.isEmpty { return .missingSpelling }
        if editingID == nil && entry(matchingTerm: term) == nil && entries.count >= Self.maxEntries && !isFromHistory {
            return .limitReached
        }
        return nil
    }
}

nonisolated enum VocabularyValidationError: Equatable {
    case emptyTerm
    case invalidTerm
    case invalidSpelling
    case duplicateTerm(existing: VocabularyEntry)
    case duplicateSpellingWithinEntry
    case spellingConflict(spelling: String, owner: VocabularyEntry)
    case missingSpelling
    case limitReached

    var message: String {
        switch self {
        case .emptyTerm: return "Enter a word or phrase."
        case .invalidTerm, .invalidSpelling: return "Remove line breaks or control characters."
        case .duplicateTerm: return "This word or phrase already exists. Edit its existing entry."
        case .duplicateSpellingWithinEntry: return "Each spelling can be listed only once."
        case .spellingConflict(let spelling, let owner): return "\u{201C}\(spelling)\u{201D} is already replaced with \u{201C}\(owner.text)\u{201D}. Edit that entry to change it."
        case .missingSpelling: return "Enter the transcript spelling you want corrected."
        case .limitReached: return "You already have \(VocabularySettings.maxEntries) vocabulary entries. Remove one to add another."
        }
    }
}

/// Stores the exact final output so later rule changes cannot alter saved results.
nonisolated struct VocabularyReplacementResult: Codable, Equatable {
    let text: String
    let appliedSpellings: [String]
}

nonisolated enum VocabularyPromptBudget {
    static let maxPromptTokens = 224

    /// Greedy whole-term inclusion in stable order. `tokenCount` measures a
    /// candidate joined prompt; returns included terms and excluded terms.
    static func includedTerms(terms: [String], tokenCount: (String) -> Int, budget: Int = maxPromptTokens) -> (included: [String], excluded: [String]) {
        var included: [String] = []
        var excluded: [String] = []
        for term in terms {
            let candidate = (included + [term]).joined(separator: ", ")
            if tokenCount(candidate) <= budget {
                included.append(term)
            } else {
                excluded.append(term)
            }
        }
        return (included, excluded)
    }
}
