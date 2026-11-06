import Foundation

/// Generates the copyable manual setup shown under Advanced config.
/// One-click setup in AgentVoiceHostInstaller performs the same registration
/// automatically; this snippet is the manual equivalent.
enum AgentVoiceHostSetup {
    static func snippet(for host: AgentVoiceHostAvailability.Host, executable: String,
                        appID: String, installationID: UUID) throws -> String {
        let arguments = ["--app-id", appID, "--installation-id", installationID.uuidString, "--host", host.hostFlag]
        switch host {
        case .codex:
            let command = try stringLiteral(executable)
            let args = try arguments.map(stringLiteral).joined(separator: ", ")
            return "[mcp_servers.dictaflow]\ncommand = \(command)\nargs = [\(args)]\ndefault_tools_approval_mode = \"approve\""
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

    /// Manual equivalent of the hooks one-click setup installs, for hosts
    /// with documented lifecycle hooks. Returns nil where no hook support is
    /// documented (Muse Code, other hosts): nothing is invented for them.
    /// Codex users merge this into ~/.codex/hooks.json and then review and
    /// trust the DictaFlow hooks with /hooks. Claude Code users merge the
    /// `hooks` value into ~/.claude/settings.json.
    static func hooksSnippet(for host: AgentVoiceHostAvailability.Host) throws -> String? {
        let events = AgentVoiceHostInstaller.expectedHookEvents(for: host)
        guard !events.isEmpty else { return nil }
        var hooks: [String: Any] = [:]
        for event in events {
            if let handler = AgentVoiceHostInstaller.expectedHookHandler(for: host, event: event) {
                hooks[event] = [["hooks": [handler]]]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks],
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
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
