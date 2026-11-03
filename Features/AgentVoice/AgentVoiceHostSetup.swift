import Foundation

/// Generates copyable setup without editing a host's configuration.
enum AgentVoiceHostSetup {
    static func snippet(for host: AgentVoiceHostAvailability.Host, executable: String,
                        appID: String, installationID: UUID) throws -> String {
        let arguments = ["--app-id", appID, "--installation-id", installationID.uuidString, "--host", host.hostFlag]
        switch host {
        case .codex:
            let command = try stringLiteral(executable)
            let args = try arguments.map(stringLiteral).joined(separator: ", ")
            return "[mcp_servers.dictaflow]\ncommand = \(command)\nargs = [\(args)]"
        case .claudeCode:
            return "claude mcp add --transport stdio dictaflow -- " + ([executable] + arguments).map(shellQuoted).joined(separator: " ")
        case .museCode:
            let configuration: [String: Any] = [
                "schema_version": 1,
                "mcp_servers": ["dictaflow": ["transport": "stdio", "command": executable, "args": arguments, "mode": "optional"]]
            ]
            let data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        case .other:
            return ([executable] + arguments).map(shellQuoted).joined(separator: " ")
        }
    }

    private static func stringLiteral(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
