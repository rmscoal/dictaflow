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
    private let hooksReferenceManagedAlias: Bool

    init(_ data: Data?) throws {
        guard let text = data.map({ String(data: $0, encoding: .utf8) }) ?? "" else { throw EditError.unsupported }
        self.text = text
        var section: [Key] = []
        var entries: [Entry] = []
        var valueDepth = 0
        var hookValues: [String] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let content = try Self.withoutComment(line)
            let first = content.firstIndex(where: { !$0.isWhitespace }) ?? content.endIndex
            guard first < content.endIndex else { continue }
            let active = content[first...]
            if valueDepth > 0 {
                if entries.last?.path.first?.name == "hooks" { hookValues.append(String(active)) }
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
                if path.first?.name == "hooks" { hookValues.append(String(active)) }
                entries.append(Entry(path: path, value: value))
            }
        }
        guard valueDepth == 0 else { throw EditError.unsupported }
        let managed = [AgentVoiceHostInstaller.legacyAlias, AgentVoiceHostInstaller.serverAlias]
        let serverTable = entries.first { $0.path.map(\.name) == ["mcp_servers"] && $0.value != nil }
        if let serverTable, let value = serverTable.value {
            entries += try Self.inlineFields(text[value]).map { field in
                Entry(path: serverTable.path + field.path, value: field.value)
            }
        }
        self.entries = try entries.flatMap { entry -> [Entry] in
            guard entry.path.count == 2, entry.path[0].name == "mcp_servers",
                  managed.contains(entry.path[1].name), let value = entry.value else { return [entry] }
            let fields = try Self.inlineFields(text[value])
            return [Entry(path: entry.path, value: nil)] + fields.map { field in
                Entry(path: entry.path + field.path, value: field.value)
            }
        }
        // Tokenize quoted strings so assignments inside a command or a comment
        // cannot be mistaken for hook fields.
        let hooks = hookValues.joined(separator: "\n")
        let tokens = /"(?:[^"\\]|\\.)*"|'[^']*'|[A-Za-z0-9_-]+|[^\s]/
        let aliases = [AgentVoiceHostInstaller.legacyAlias, AgentVoiceHostInstaller.serverAlias]
        let parts = hooks.matches(of: tokens).map(\.output)
        hooksReferenceManagedAlias = try parts.indices.dropLast(2).contains { index in
            guard parts[index + 1] == "=" else { return false }
            let keyToken = parts[index]
            let key: String
            if keyToken.first == "\"" || keyToken.first == "'" {
                guard let decoded = Self.string(keyToken) else { throw EditError.unsupported }
                key = decoded
            } else {
                key = String(keyToken)
            }
            guard key == "server" || key == "matcher" else { return false }
            let token = parts[index + 2]
            guard let value = Self.string(token) else { throw EditError.unsupported }
            return aliases.contains {
                key == "server" ? value == $0 : value.contains("mcp__\($0)__")
            }
        }
    }

    var aliases: Set<String> {
        Set(entries.compactMap {
            $0.path.first?.name == "mcp_servers" && $0.path.count > 1 ? $0.path[1].name : nil
        })
    }

    /// The top-level inline `mcp_servers` entry, when the table is written as
    /// `mcp_servers = { name = { ... }, ... }` on one line.
    private var inlineServersEntry: Entry? {
        entries.first { $0.path.map(\.name) == ["mcp_servers"] && $0.value != nil }
    }

    func candidate(executable: String, arguments: [String], newEntryDisabled: Bool = false, ownsPath: (String) -> Bool) throws -> Data {
        let old = AgentVoiceHostInstaller.legacyAlias
        let new = AgentVoiceHostInstaller.serverAlias
        guard !hooksReferenceManagedAlias else { throw AgentVoiceHostMigration.Failure.unownedHook }
        if aliases.contains(old), aliases.contains(new) { throw EditError.collision }
        guard aliases.contains(old) || aliases.contains(new) else {
            let values = try arguments.map(Self.literal).joined(separator: ", ")
            if let inline = inlineServersEntry, let range = inline.value {
                // An inline table cannot gain a `[mcp_servers.omdo]` section,
                // so insert the new entry inside the existing table and leave
                // every unrelated entry byte-for-byte unchanged.
                let value = text[range]
                guard let closing = value.lastIndex(of: "}") else { throw EditError.unsupported }
                let inner = value[value.index(after: value.startIndex)..<closing]
                let separator = inner.allSatisfy(\.isWhitespace) ? "" : ", "
                let enabled = newEntryDisabled ? ", enabled = false" : ""
                let entry = "\(new) = { command = \(try Self.literal(executable)), args = [\(values)], default_tools_approval_mode = \"approve\"\(enabled) }"
                var output = text
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.distance(from: range.lowerBound, to: range.upperBound)
                let lower = output.index(output.startIndex, offsetBy: start)
                output.replaceSubrange(lower..<output.index(lower, offsetBy: length),
                                       with: String(value[..<closing]) + separator + entry + " }")
                return Data(output.utf8)
            }
            let enabled = newEntryDisabled ? "enabled = false\n" : ""
            let server = "\n\n[mcp_servers.\(new)]\ncommand = \(try Self.literal(executable))\nargs = [\(values)]\ndefault_tools_approval_mode = \"approve\"\n\(enabled)"
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
        // The helper path proves ownership. Recorded arguments embed the
        // previous installation's app ID and random installation ID, so they
        // are rewritten to the current values instead of required to match.
        guard let command = Self.string(text[commandRange]), ownsPath(command) else { throw EditError.unknownOwner }

        let argsRange = try singleton("args")
        var replacements: [Range<String.Index>: String] = [:]
        if command != executable { replacements[commandRange] = try Self.literal(executable) }
        if try Self.stringArray(text[argsRange]) != arguments {
            let values = try arguments.map(Self.literal).joined(separator: ", ")
            replacements[argsRange] = "[\(values)]"
        }
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

    /// Separates fields only at the current inline table depth. Parse each
    /// field's full key path so quoted dots remain part of the key.
    private static func inlineFields(_ value: Substring) throws -> [Entry] {
        guard value.first == "{", value.last == "}" else { throw EditError.unsupported }
        let inner = value.dropFirst().dropLast()
        if inner.allSatisfy(\.isWhitespace) { return [] }
        var fields: [Entry] = []
        var start = inner.startIndex
        var depth = 0
        for index in try separators("{[}],", in: inner) + [inner.endIndex] {
            if index != inner.endIndex {
                switch inner[index] {
                case "{", "[": depth += 1; continue
                case "}", "]":
                    depth -= 1
                    guard depth >= 0 else { throw EditError.unsupported }
                    continue
                default:
                    if depth > 0 { continue }
                }
            }
            let field = inner[start..<index]
            guard depth == 0, let equals = try unquotedEquals(field) else { throw EditError.unsupported }
            let rest = field[field.index(after: equals)...]
            guard let a = rest.firstIndex(where: { !$0.isWhitespace }),
                  let b = rest.lastIndex(where: { !$0.isWhitespace }) else { throw EditError.unsupported }
            fields.append(Entry(path: try keys(field[..<equals]), value: a..<rest.index(after: b)))
            if index != inner.endIndex { start = inner.index(after: index) }
        }
        return fields
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
