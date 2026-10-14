import Foundation

/// Conservative presentation rules. This does not infer grammar or rewrite meaning.
nonisolated enum TextToneFormatter {
    static let version = 1

    private static let contractions: [String: String] = [
        "i'm": "I am", "you're": "you are", "we're": "we are", "they're": "they are",
        "i've": "I have", "you've": "you have", "we've": "we have", "they've": "they have",
        "i'll": "I will", "you'll": "you will", "we'll": "we will", "they'll": "they will",
        "can't": "cannot", "won't": "will not", "don't": "do not", "doesn't": "does not",
        "didn't": "did not", "isn't": "is not", "aren't": "are not", "wasn't": "was not",
        "weren't": "were not", "haven't": "have not", "hasn't": "has not",
        "there's": "there is", "gonna": "going to"
    ]
    private static let sentenceWords: Set<String> = [
        "i", "a", "an", "the", "this", "that", "there", "here", "it", "we", "you", "they",
        "he", "she", "my", "our", "your", "please", "thanks", "hello", "hi", "hmm", "um", "uh",
        "yes", "no", "okay", "ok", "and", "but", "so", "when", "what", "why", "how", "if"
    ]

    static func format(_ text: String, tone: TextTone, isEnglish: Bool, protectedTerms: [String] = []) -> ToneFormattingResult {
        guard tone != .original, tone != .balanced, !text.isEmpty else {
            return ToneFormattingResult(tone: tone, formatterVersion: version, text: text)
        }
        let source = text as NSString
        // Protect structured text before processing words. Numbers and punctuation inside these
        // spans are never modified. Unknown names and mixed-case identifiers are preserved below.
        let structured = try! NSRegularExpression(pattern: #"(?s)```.*?(?:```|$)|`[^`\n]*(?:`|$)|https?://[^\s]+|www\.[^\s]+|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|\b[\w]*[\d_][\w.:-]*\b|\b[\p{L}_][\p{L}\p{N}_]*(?:\.[\p{L}_][\p{L}\p{N}_]*)+\b"#, options: .caseInsensitive)
        var protectedRanges = structured.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        let acronyms = try! NSRegularExpression(pattern: #"\b\p{Lu}{2,}\b"#)
        protectedRanges += acronyms.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        // “Uh huh” is an affirmation, rather than an opening hesitation.
        let affirmation = try! NSRegularExpression(pattern: #"^(?i:uh[ -]huh)\b"#)
        protectedRanges += affirmation.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
        for term in protectedTerms where !term.isEmpty {
            let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}_])"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                protectedRanges += regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
            }
        }
        let words = try! NSRegularExpression(pattern: #"[\p{L}]+(?:['’][\p{L}]+)*"#)
        let output = NSMutableString(string: text)
        for match in words.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let word = source.substring(with: match.range)
            let lower = word.lowercased().replacingOccurrences(of: "’", with: "'")
            let isKnown = sentenceWords.contains(lower) || contractions[lower] != nil
            let isLowercase = word == word.lowercased()
            // Capitalized unknown words may be names. All caps may be acronyms.
            guard isLowercase || isKnown else { continue }
            if tone == .casual {
                let replacement = isEnglish && contractions[lower] != nil
                    ? lower.replacingOccurrences(of: "'", with: "") : word.lowercased()
                output.replaceCharacters(in: match.range, with: replacement)
            } else if isEnglish {
                var replacement = lower == "i" ? "I" : word
                if let expansion = contractions[lower] {
                    // “There's” can also mean “there has”. Expand only the clear article form.
                    let following = source.substring(from: NSMaxRange(match.range))
                    let isClearThereIs = following.range(of: #"^\s+(?:a|an)\s"#, options: [.regularExpression, .caseInsensitive]) != nil
                    if lower != "there's" || isClearThereIs { replacement = expansion }
                }
                let prefix = source.substring(to: match.range.location)
                let preceding = prefix.trimmingCharacters(in: .whitespacesAndNewlines).last
                let followsOpeningFiller = !protectedRanges.contains(where: { $0.location == 0 })
                    && prefix.range(of: #"^(?:(?i:hmm|um|uh)[,\s]+)+$"#, options: .regularExpression) != nil
                let startsSentence = preceding == nil || preceding == "." || preceding == "!" || preceding == "?" || followsOpeningFiller
                if word.first?.isUppercase == true || startsSentence {
                    replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
                }
                output.replaceCharacters(in: match.range, with: replacement)
            }
        }
        var result = output as String
        if tone == .formal && isEnglish {
            // Only a leading filler followed by a separator is unambiguous enough to remove.
            if !protectedRanges.contains(where: { $0.location == 0 }) {
                result = result.replacingOccurrences(of: #"^(?:(?i:hmm|um|uh)[,\s]+)+"#, with: "", options: .regularExpression)
            }
        }
        // Touch only a terminal prose period. Keep multiline text, code, URLs and numeric endings.
        if !result.contains("\n"), !result.contains("`"),
           let end = result.lastIndex(where: { !$0.isWhitespace }) {
            let last = result[end]
            let trailingLength = result[result.index(after: end)...].utf16.count
            let structuredEnding = protectedRanges.contains { NSMaxRange($0) >= source.length - trailingLength - 1 }
            if tone == .casual, last == ".", !structuredEnding, result[..<end].last != "." {
                result.remove(at: end)
            } else if tone == .formal, last.isLetter, !structuredEnding {
                result.insert(".", at: result.index(after: end))
            }
        }
        return ToneFormattingResult(tone: tone, formatterVersion: version, text: result)
    }
}
