import Foundation

/// A local, best-effort rendering for speech. The submitted rendition stays in
/// history; the agent remains responsible for explaining code and technical details.
enum LiquidSpeechText {
    static let codeNotice = "Code is available in the written answer."
    static let tableNotice = "The table is available in the written answer."
    static let emptyNotice = "Please read the written answer for details."
    static let identifierNotice = "an identifier in the written answer"

    static func normalize(_ text: String) -> String {
        let prose = markdownProse(text)
        let links = replacingWebLinks(prose)
        let result = replacingLongIdentifiers(links).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? emptyNotice : result
    }

    private static func markdownProse(_ text: String) -> String {
        // Foundation's Markdown parser preserves inline code, link/image labels,
        // and escaped punctuation without broad character-stripping rules.
        guard let parsed = try? AttributedString(markdown: text) else { return text }
        var paragraphs: [String] = []
        var current = ""
        var identity: Int?
        var listItem: Int?
        var seenListItems: Set<Int> = []
        var startsWithCode = false
        var containsCode = false
        func flush() {
            var prose = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if let listItem, seenListItems.insert(listItem).inserted, !startsWithCode {
                prose = spokenTaskMarker(prose)
            }
            if !containsCode, isLooseTable(prose) { prose = tableNotice }
            if !prose.isEmpty { paragraphs.append(prose) }
            current = ""
            startsWithCode = false
            containsCode = false
        }
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            if components.contains(where: { if case .thematicBreak = $0.kind { return true }; return false }) {
                flush(); identity = nil; listItem = nil
                continue
            }
            let reference = components.first {
                switch $0.kind {
                case .codeBlock, .table: return true
                default: return false
                }
            }
            let nextIdentity = reference?.identity ?? components.first?.identity
            if identity != nextIdentity {
                flush(); identity = nextIdentity
                listItem = components.first { if case .listItem = $0.kind { return true }; return false }?.identity
            }
            if let reference {
                if current.isEmpty {
                    switch reference.kind {
                    case .codeBlock: current = codeNotice
                    default: current = tableNotice
                    }
                }
            } else {
                let isCode = run.inlinePresentationIntent?.contains(.code) == true
                let isHTML = run.inlinePresentationIntent?.contains(.inlineHTML) == true
                    || run.inlinePresentationIntent?.contains(.blockHTML) == true
                let raw = String(parsed[run.range].characters)
                let prose: String
                if isHTML, !isCode { prose = formattingHTML(raw) }
                else if run.inlinePresentationIntent?.contains(.softBreak) == true { prose = "\n" }
                else { prose = raw }
                if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { startsWithCode = isCode }
                containsCode = containsCode || isCode
                current += prose
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
            .replacingOccurrences(of: "\\n[\\t \\n]*\\n", with: "\n\n", options: .regularExpression)
    }

    private static func spokenTaskMarker(_ text: String) -> String {
        let marker = String(text.prefix(3))
        guard ["[x]", "[X]", "[ ]"].contains(marker) else { return text }
        let rest = text.dropFirst(3)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return text }
        let status = marker == "[ ]" ? "Pending" : "Completed"
        let task = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return task.isEmpty ? status + "." : status + ": " + task
    }

    private static func formattingHTML(_ text: String) -> String {
        // Only parser-identified HTML is eligible. Known formatting tags avoid
        // mistaking generic types for markup; quoted '>' attributes stay intact.
        let pattern = #"</?([A-Za-z][A-Za-z0-9]*)(?=[\s/>])(?:[^<>"']++|"[^"]*"|'[^']*')*>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let inline: Set<String> = ["a", "b", "strong", "i", "em", "u", "s", "strike", "del", "small", "span", "mark", "sub", "sup", "code", "kbd", "samp", "var"]
        let breaks: Set<String> = ["br", "hr", "p", "div", "section", "article", "blockquote", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6"]
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let nameRange = Range(match.range(at: 1), in: result),
                  let range = Range(match.range, in: result) else { continue }
            let name = result[nameRange].lowercased()
            if inline.contains(name) { result.replaceSubrange(range, with: "") }
            else if breaks.contains(name) { result.replaceSubrange(range, with: "\n\n") }
        }
        return result
    }

    private static func isLooseTable(_ text: String) -> Bool {
        // Restrict the fallback to multiple, consistently shaped bordered rows.
        // Inline code, ordinary pipelines, and logical OR remain literal content.
        let rows = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard rows.count >= 2 else { return false }
        var columns: Int?
        for row in rows {
            guard row.hasPrefix("|"), row.hasSuffix("|"), !row.contains("||") else { return false }
            let count = row.split(separator: "|", omittingEmptySubsequences: false).count - 2
            guard count >= 2, columns == nil || columns == count else { return false }
            columns = count
        }
        return true
    }

    private static func replacingWebLinks(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        var result = text
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let url = match.url, let range = Range(match.range, in: result) else { continue }
            let replacement: String
            if url.isFileURL {
                replacement = url.lastPathComponent
            } else if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host {
                replacement = host.count > 120 ? "a link in the written answer"
                    : host + (url.port.map { " port \($0)" } ?? "")
            } else { continue }
            if !replacement.isEmpty { result.replaceSubrange(range, with: replacement) }
        }
        return result
    }

    /// Replaces unspaced tokens longer than `limit` with a short spoken notice, leaving non-Latin prose intact.
    static func replacingLongIdentifiers(_ text: String, limit: Int = 320) -> String {
        guard let expression = try? NSRegularExpression(pattern: "\\S{\(limit + 1),}") else { return text }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = result[range]
            // Unspaced non-Latin prose is handled by the language-aware planner.
            guard token.count > limit, !token.unicodeScalars.contains(where: {
                CharacterSet.letters.contains($0) && $0.value > 0x024F
            }) else { continue }
            let ending = token.last.map { ".!?;:,".contains($0) ? String($0) : "" } ?? ""
            result.replaceSubrange(range, with: identifierNotice + ending)
        }
        return result
    }
}
