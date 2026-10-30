import Foundation

/// Pure deterministic replacement pass. Literal, case-insensitive,
/// Unicode-aware matching on complete words/phrases. No regex or fuzzy logic
/// is interpreted in user input.
nonisolated enum TextReplacementProcessor {
    struct Output: Equatable {
        let text: String
        let appliedSpellings: [String]
    }

    static func apply(_ text: String, rules: [VocabularyReplacementRule]) -> Output {
        guard !text.isEmpty, !rules.isEmpty else {
            return Output(text: text, appliedSpellings: [])
        }
        // Longest trigger first so the longest match wins at a position.
        let prepared = rules
            .map { (rule: $0, chars: Array($0.trigger), folded: Array($0.trigger).map(fold)) }
            .filter { !$0.chars.isEmpty }
            .sorted { $0.chars.count > $1.chars.count }
        guard !prepared.isEmpty else { return Output(text: text, appliedSpellings: []) }

        let input = Array(text)
        var output = ""
        output.reserveCapacity(text.count)
        var applied: [String] = []
        var seenApplied = Set<String>()
        var index = 0
        while index < input.count {
            var matched: (rule: VocabularyReplacementRule, length: Int)?
            if index == 0 || !isTokenCharacter(input[index - 1]) {
                for candidate in prepared {
                    let length = candidate.chars.count
                    guard index + length <= input.count else { continue }
                    let end = index + length
                    if end < input.count && isTokenCharacter(input[end]) { continue }
                    var matches = true
                    for offset in 0..<length where fold(input[index + offset]) != candidate.folded[offset] {
                        matches = false
                        break
                    }
                    if matches { matched = (candidate.rule, length); break }
                }
            }
            if let matched {
                output += matched.rule.replacement
                let key = VocabularySettings.normalizedKey(matched.rule.trigger)
                if !seenApplied.contains(key) {
                    seenApplied.insert(key)
                    applied.append(matched.rule.trigger)
                }
                index += matched.length
            } else {
                output.append(input[index])
                index += 1
            }
        }
        return Output(text: output, appliedSpellings: applied)
    }

    private static func fold(_ character: Character) -> String {
        String(character).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Letters, numbers, underscore and apostrophes join words into one token,
    /// so `can` never matches inside `can't` and a possessive stays one token.
    /// Hyphens and other punctuation separate tokens.
    static func isTokenCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.nonBaseCharacters.contains(scalar)
                || scalar == "_"
                || scalar == "'"
                || scalar == "\u{2019}"
                || scalar == "\u{02BC}"
        }
    }
}
