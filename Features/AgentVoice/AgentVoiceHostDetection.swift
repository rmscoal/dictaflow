import Foundation

/// Local-only availability probing for Agent Voice setup guidance.
/// Reports whether a host's CLI exists in the searched locations. This never
/// implies a live MCP connection, configured server entry, or qualified
/// host hooks. One-click setup writes only that host's DictaFlow MCP entry;
/// manual copy remains under Advanced config.
struct AgentVoiceHostAvailability {
    enum Host: String, CaseIterable, Identifiable {
        case codex
        case claudeCode
        case museCode
        case other

        var id: String { rawValue }

        var name: String {
            switch self {
            case .codex: "Codex"
            case .claudeCode: "Claude Code"
            case .museCode: "Muse Code"
            case .other: "Other hosts"
            }
        }

        var hostFlag: String {
            switch self {
            case .codex: "codex"
            case .claudeCode: "claude"
            case .museCode: "muse"
            case .other: "other"
            }
        }

        /// Desktop applications do not establish that their separate CLI is installed.
        var cliNames: [String] {
            switch self {
            case .codex: ["codex"]
            case .claudeCode: ["claude"]
            case .museCode: ["muse"]
            case .other: []
            }
        }

        var docsURL: URL? {
            switch self {
            case .codex: URL(string: "https://developers.openai.com/codex/mcp")
            case .claudeCode: URL(string: "https://code.claude.com/docs/en/mcp")
            case .museCode: URL(string: "https://dev.meta.ai/docs/muse-code/configuration")
            case .other: URL(string: "https://modelcontextprotocol.io/docs/develop/build-server#stdio")
            }
        }

        var docsLabel: String {
            switch self {
            case .other: "MCP stdio documentation"
            default: "\(name) MCP documentation"
            }
        }
    }

    struct Result {
        let foundCLI: String?
        var isDetected: Bool { foundCLI != nil }
    }

    /// GUI launches often lack the user's shell PATH. Include common install
    /// locations and NVM versions without launching a shell or reading its config.
    static func cliPath(for name: String) -> String? {
        var directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.volta/bin",
        ]
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") }
        let nodeRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".nvm/versions/node")
        let nodeVersions = (try? FileManager.default.contentsOfDirectory(at: nodeRoot, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])) ?? []
        directories += nodeVersions.sorted { $0.lastPathComponent > $1.lastPathComponent }.map { $0.appendingPathComponent("bin").path }
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func check(_ host: Host) -> Result {
        let cli = host.cliNames.compactMap { cliPath(for: $0) }.first
        return Result(foundCLI: cli)
    }
}
