import Foundation
import NaturalLanguage

protocol LiquidLanguageRecognizing: Sendable {
    func hypotheses(for text: String) -> [String: Double]
}

struct NaturalLiquidLanguageRecognizer: LiquidLanguageRecognizing {
    func hypotheses(for text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum: 3).map {
            ($0.key.rawValue, $0.value)
        })
    }
}

struct LiquidSpeechChunk: Equatable, Sendable {
    let text: String
    let language: String
    let startsParagraph: Bool
}

/// A derived synthesis plan. The complete, original rendition remains in history.
struct LiquidSpeechPlan: Sendable {
    let chunks: [LiquidSpeechChunk]
    static let previewNotice = "This is a spoken preview. The full response is available in the written answer."
    static let maximumWords = 240
    static let maximumCharacters = 1_600
    static let maximumChunks = 8

    // The pinned model's speech languages. Chinese script variants share one voice code.
    private static let supported: Set<String> = [
        "en", "ar", "da", "de", "el", "fi", "fr", "he", "it", "ja", "ko", "nl", "pl", "pt", "es", "sv", "tr", "zh"
    ]

    static func make(_ text: String,
                     recognizer: any LiquidLanguageRecognizing = NaturalLiquidLanguageRecognizer()) throws -> Self {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 8_000 else {
            throw VoiceError.unavailable("The spoken rendition is empty or too long.")
        }
        let spokenText = LiquidSpeechText.normalize(text)
        let paragraphs = paragraphs(in: spokenText)
        // The whole rendition is only context: separately clear language paragraphs
        // may be mixed. Each paragraph is still validated before any synthesis.
        let context = paragraphs.first { $0.split(whereSeparator: \.isWhitespace).count >= 4 } ?? paragraphs[0]
        let fallback = (try? language(for: spokenText, fallback: nil, recognizer: recognizer))
            ?? (try? language(for: context, fallback: nil, recognizer: recognizer))
        var chunks: [LiquidSpeechChunk] = []
        for paragraph in paragraphs {
            let language = try language(for: paragraph, fallback: fallback, recognizer: recognizer)
            let limits = Limits(language: language)
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            tokenizer.setLanguage(NLLanguage(rawValue: language))
            var sentences: [String] = []
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let sentence = String(paragraph[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                return true
            }
            if sentences.isEmpty { sentences = [paragraph] }

            var group: [String] = []
            var first = true
            func flush() {
                guard !group.isEmpty else { return }
                chunks.append(LiquidSpeechChunk(text: group.joined(separator: " "), language: language,
                                               startsParagraph: first))
                first = false
                group.removeAll(keepingCapacity: true)
            }
            for sentence in sentences {
                for piece in try split(sentence, limits: limits) {
                    if !group.isEmpty && (group.count >= limits.sentences || !limits.contains((group + [piece]).joined(separator: " "))) {
                        flush()
                    }
                    group.append(piece)
                }
            }
            flush()
        }
        return boundedPreview(chunks)
    }

    /// Admission stays permissive. The shared budgets prevent a foreign-language
    /// chunk from bypassing the work bound. They do not predict exact audio duration.
    /// The English app notice is separate; retained chunks keep their own language.
    private static func boundedPreview(_ chunks: [LiquidSpeechChunk]) -> Self {
        let text = chunks.map(\.text).joined(separator: "\n\n")
        guard text.split(whereSeparator: \.isWhitespace).count > maximumWords
                || text.count > maximumCharacters || chunks.count > maximumChunks else {
            return Self(chunks: chunks)
        }
        var preview = [LiquidSpeechChunk(text: previewNotice, language: "en", startsParagraph: true)]
        var words = previewNotice.split(whereSeparator: \.isWhitespace).count
        var characters = previewNotice.count
        for chunk in chunks {
            let nextWords = chunk.text.split(whereSeparator: \.isWhitespace).count
            guard preview.count < maximumChunks,
                  words + nextWords <= maximumWords,
                  characters + 2 + chunk.text.count <= maximumCharacters else { break }
            preview.append(chunk)
            words += nextWords
            characters += 2 + chunk.text.count
        }
        return Self(chunks: preview)
    }

    private struct Limits {
        let characters: Int
        let words: Int
        let sentences: Int
        let splitsUnspacedText: Bool

        init(language: String) {
            let english = language == "en"
            splitsUnspacedText = ["zh", "ja", "ko"].contains(language)
            characters = english ? 320 : (splitsUnspacedText ? 60 : 160)
            words = english ? 50 : 25
            // Multilingual grouping is deliberately conservative until separately qualified.
            sentences = english ? 3 : 1
        }

        func contains(_ text: String) -> Bool {
            text.count <= characters && text.split(whereSeparator: \.isWhitespace).count <= words
        }
    }

    private static func paragraphs(in text: String) -> [String] {
        var result: [String] = []
        var lines: [String] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !lines.isEmpty { result.append(lines.joined(separator: " ")); lines.removeAll() }
            } else { lines.append(trimmed) }
        }
        if !lines.isEmpty { result.append(lines.joined(separator: " ")) }
        return result
    }

    private static func language(for text: String, fallback: String?, recognizer: any LiquidLanguageRecognizing) throws -> String {
        // A short Latin-script heading/name is less reliable than its containing rendition.
        let hasOtherScript = text.unicodeScalars.contains { CharacterSet.letters.contains($0) && $0.value > 0x024F }
        let candidates = recognizer.hypotheses(for: text).sorted { $0.value > $1.value }
        if let fallback, text.split(whereSeparator: \.isWhitespace).count < 4, !hasOtherScript {
            // A clearly recognized, complete supported phrase can override context;
            // isolated headings such as "Models" still inherit it.
            if text.split(whereSeparator: \.isWhitespace).count >= 2,
               text.last.map({ ".!?".contains($0) }) == true,
               let candidate = candidates.first, candidate.value >= 0.90, supported.contains(candidate.key) {
                return candidate.key
            }
            return fallback
        }
        if let candidate = candidates.first, candidate.value >= 0.70 {
            let code = candidate.key.hasPrefix("zh") ? "zh" : candidate.key
            guard supported.contains(code) else {
                let name = Locale.current.localizedString(forLanguageCode: code) ?? code
                throw VoiceError.unavailable("Liquid does not support \(name) speech. Use a supported language for the spoken response.")
            }
            return code
        }
        if let fallback { return fallback }
        // Very short acknowledgements/numbers often have no reliable language signal.
        if text.split(whereSeparator: \.isWhitespace).count < 4, text.count < 40 { return "en" }
        throw VoiceError.unavailable("Liquid could not identify the spoken response language. Use clear prose in one supported language per paragraph.")
    }

    private static func split(_ sentence: String, limits: Limits) throws -> [String] {
        if limits.contains(sentence) { return [sentence] }
        // Prefer clause boundaries. Do not cut a number, URL, or time at its punctuation.
        var clauses: [String] = []
        var start = sentence.startIndex
        for index in sentence.indices {
            let next = sentence.index(after: index)
            if ",;:，；：、".contains(sentence[index]),
               next == sentence.endIndex || sentence[next].isWhitespace || limits.splitsUnspacedText {
                clauses.append(String(sentence[start..<next]).trimmingCharacters(in: .whitespacesAndNewlines))
                start = next
            }
        }
        if start < sentence.endIndex {
            clauses.append(String(sentence[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var result: [String] = []
        for clause in clauses where !clause.isEmpty {
            if limits.contains(clause) { result.append(clause); continue }
            var words: [String] = []
            for word in clause.split(whereSeparator: \.isWhitespace).map(String.init) {
                if word.count > limits.characters {
                    if !words.isEmpty { result.append(words.joined(separator: " ")); words.removeAll() }
                    guard limits.splitsUnspacedText else {
                        throw VoiceError.unavailable("The spoken response contains a very long word, link, or identifier. Describe it in shorter spoken phrases.")
                    }
                    var remaining = word[...]
                    while !remaining.isEmpty {
                        let piece = remaining.prefix(limits.characters)
                        result.append(String(piece)); remaining = remaining.dropFirst(piece.count)
                    }
                } else {
                    if !words.isEmpty && !limits.contains((words + [word]).joined(separator: " ")) {
                        result.append(words.joined(separator: " ")); words.removeAll()
                    }
                    words.append(word)
                }
            }
            if !words.isEmpty { result.append(words.joined(separator: " ")) }
        }
        return result
    }
}
