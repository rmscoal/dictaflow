import Foundation

/// Source ranges for TOML keys let us rekey a server without rewriting its policy
/// or unrelated settings. Unsupported forms are handled by the manual setup.
nonisolated struct CodexMCPConfiguration {
    enum EditError: LocalizedError {
        case unsupported, collision, unknownOwner

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Omdo could not safely edit this Codex config. Use the manual migration below."
            case .collision: return "Both dictaflow and omdo are defined in this Codex profile. Review the entries before retrying."
            case .unknownOwner: return "The server entry does not belong to this Omdo installation. Review it before retrying."
            }
        }
    }

    private struct Key {
        let name: String
        let range: Range<String.Index>
    }

    private struct Entry {
        let path: [Key]
        let value: Range<String.Index>?
    }

    private let text: String
    private let entries: [Entry]

    init(_ data: Data?) throws {
        guard let text = data.map({ String(data: $0, encoding: .utf8) }) ?? "" else { throw EditError.unsupported }
        self.text = text
        var section: [Key] = []
        var entries: [Entry] = []
        var valueDepth = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let content = try Self.withoutComment(line)
            let first = content.firstIndex(where: { !$0.isWhitespace }) ?? content.endIndex
            guard first < content.endIndex else { continue }
            let active = content[first...]
            if valueDepth > 0 {
                valueDepth += try Self.bracketBalance(active)
                guard valueDepth >= 0 else { throw EditError.unsupported }
                continue
            }
            if active.first == "[" {
                let array = active.hasPrefix("[[")
                let count = array ? 2 : 1
                guard let last = active.lastIndex(where: { !$0.isWhitespace }),
                      active[...last].hasSuffix(array ? "]]" : "]") else { throw EditError.unsupported }
                section = try Self.keys(active[...last].dropFirst(count).dropLast(count))
                if array, section.first?.name == "mcp_servers" { throw EditError.unsupported }
                entries.append(Entry(path: section, value: nil))
            } else {
                guard let equals = try Self.unquotedEquals(active) else { throw EditError.unsupported }
                let path = section + (try Self.keys(active[..<equals]))
                let rest = active[active.index(after: equals)...]
                guard let start = rest.firstIndex(where: { !$0.isWhitespace }),
                      let end = rest.lastIndex(where: { !$0.isWhitespace }) else { throw EditError.unsupported }
                let value = start..<rest.index(after: end)
                valueDepth = try Self.bracketBalance(rest[value])
                guard valueDepth >= 0 else { throw EditError.unsupported }
                if path.first?.name == "mcp_servers", valueDepth != 0,
                   path.count < 3 || path[2].name == "command" || path[2].name == "args" {
                    throw EditError.unsupported
                }
                entries.append(Entry(path: path, value: value))
            }
        }
        guard valueDepth == 0 else { throw EditError.unsupported }
        // Inline server tables cannot be individually verified by this editor.
        if entries.contains(where: { $0.path.first?.name == "mcp_servers" && $0.path.count < 3 && $0.value != nil }) {
            throw EditError.unsupported
        }
        self.entries = entries
    }

    var aliases: Set<String> {
        Set(entries.compactMap {
            $0.path.first?.name == "mcp_servers" && $0.path.count > 1 ? $0.path[1].name : nil
        })
    }

    func candidate(executable: String, arguments: [String], ownsPath: (String) -> Bool) throws -> Data {
        let old = AgentVoiceHostInstaller.legacyAlias
        let new = AgentVoiceHostInstaller.serverAlias
        if aliases.contains(old), aliases.contains(new) { throw EditError.collision }
        guard aliases.contains(old) || aliases.contains(new) else {
            let values = try arguments.map(Self.literal).joined(separator: ", ")
            let server = "\n\n[mcp_servers.\(new)]\ncommand = \(try Self.literal(executable))\nargs = [\(values)]\ndefault_tools_approval_mode = \"approve\"\n"
            return Data((text + server).utf8)
        }
        let alias = aliases.contains(old) ? old : new
        let owned = entries.filter { $0.path.first?.name == "mcp_servers" && $0.path.dropFirst().first?.name == alias }
        func singleton(_ key: String) throws -> Range<String.Index> {
            let values = owned.filter { $0.path.map(\.name) == ["mcp_servers", alias, key] }.compactMap(\.value)
            guard values.count == 1, let value = values.first else { throw EditError.unsupported }
            return value
        }
        let commandRange = try singleton("command")
        let argsRange = try singleton("args")
        guard let command = Self.string(text[commandRange]), ownsPath(command),
              try Self.stringArray(text[argsRange]) == arguments else { throw EditError.unknownOwner }

        var replacements: [Range<String.Index>: String] = [:]
        if command != executable { replacements[commandRange] = try Self.literal(executable) }
        if alias == old {
            for entry in owned { replacements[entry.path[1].range] = new }
        }
        var output = text
        // Use offsets into the original string since String.Index can be invalidated on edit.
        for (range, replacement) in replacements.sorted(by: { $0.key.lowerBound > $1.key.lowerBound }) {
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            let lower = output.index(output.startIndex, offsetBy: start)
            output.replaceSubrange(lower..<output.index(lower, offsetBy: length), with: replacement)
        }
        return Data(output.utf8)
    }

    func isDisabled(alias: String) -> Bool {
        entries.contains {
            $0.path.map(\.name) == ["mcp_servers", alias, "enabled"] && $0.value.map { text[$0] == "false" } == true
        }
    }

    private static func keys(_ text: Substring) throws -> [Key] {
        var start = text.startIndex
        var result: [Key] = []
        for index in try separators(".", in: text) + [text.endIndex] {
            let piece = text[start..<index]
            guard let a = piece.firstIndex(where: { !$0.isWhitespace }),
                  let b = piece.lastIndex(where: { !$0.isWhitespace }) else { throw EditError.unsupported }
            let range = a..<piece.index(after: b)
            let value = piece[range]
            if value.first == "'" || value.first == "\"" {
                guard let decoded = string(value) else { throw EditError.unsupported }
                result.append(Key(name: decoded, range: range))
            } else {
                guard value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw EditError.unsupported }
                result.append(Key(name: String(value), range: range))
            }
            if index != text.endIndex { start = text.index(after: index) }
        }
        return result
    }

    private static func string(_ token: Substring) -> String? {
        guard token.count >= 2 else { return nil }
        if token.first == "'", token.last == "'", !token.dropFirst().dropLast().contains("'") {
            return String(token.dropFirst().dropLast())
        }
        if token.first == "\"" { return try? JSONDecoder().decode(String.self, from: Data(token.utf8)) }
        return nil
    }

    private static func stringArray(_ value: Substring) throws -> [String]? {
        guard value.first == "[", value.last == "]" else { return nil }
        let inner = value.dropFirst().dropLast()
        var start = inner.startIndex
        var strings: [String] = []
        for index in try separators(",", in: inner) + [inner.endIndex] {
            let token = inner[start..<index].trimmingCharacters(in: .whitespaces)
            if index == inner.endIndex, token.isEmpty { break }
            guard let decoded = string(token[...]) else { return nil }
            strings.append(decoded)
            if index != inner.endIndex { start = inner.index(after: index) }
        }
        return strings
    }

    private static func literal(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func withoutComment(_ text: Substring) throws -> Substring {
        if let comment = try separators("#", in: text, stopAtFirst: true).first { return text[..<comment] }
        return text
    }

    private static func unquotedEquals(_ text: Substring) throws -> String.Index? {
        try separators("=", in: text, stopAtFirst: true).first
    }

    private static func bracketBalance(_ text: Substring) throws -> Int {
        try separators("[{", in: text).count - separators("]}", in: text).count
    }

    private static func separators(_ wanted: String, in text: Substring, stopAtFirst: Bool = false) throws -> [String.Index] {
        var result: [String.Index] = []
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if let active = quote {
                if escaped { escaped = false }
                else if character == "\\", active == "\"" { escaped = true }
                else if character == active { quote = nil }
            } else if character == "'" || character == "\"" {
                if text[index...].hasPrefix(String(repeating: String(character), count: 3)) { throw EditError.unsupported }
                quote = character
            } else if wanted.contains(character) {
                result.append(index)
                if stopAtFirst { return result }
            }
        }
        guard quote == nil else { throw EditError.unsupported }
        return result
    }
}
