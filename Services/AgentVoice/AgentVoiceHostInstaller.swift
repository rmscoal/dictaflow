import Foundation

/// One-click host setup for Agent Voice. Registers the bundled dictaflow-mcp
/// helper with Codex, Claude Code, or Muse Code, then verifies the entry.
/// Codex and Claude also receive user-level lifecycle hook definitions.
/// A configured entry means the
/// host can find the server, not that a live MCP connection exists: the
/// connection happens inside a new host session.
enum AgentVoiceHostInstaller {
    typealias Host = AgentVoiceHostAvailability.Host

    // MARK: - State

    struct HostState: Equatable, Sendable {
        var cliPath: String?
        var configuredEntryFound: Bool
        var entryMatchesCurrent: Bool
        /// Native lifecycle hooks in the host's user-level hook file.
        /// Always false for hosts with no documented hook support.
        var hooksEntryFound: Bool = false
        var hooksMatchCurrent: Bool = false

        var hooksConfigured: Bool { hooksEntryFound && hooksMatchCurrent }

        enum Status: Equatable, Sendable {
            case manualOnly
            case notFound
            case foundNotConfigured
            case configured
        }

        var status: Status {
            if configuredEntryFound, entryMatchesCurrent { return .configured }
            if cliPath != nil { return .foundNotConfigured }
            return .notFound
        }

        static func manualOnly(cliPath: String?) -> HostState {
            HostState(cliPath: cliPath, configuredEntryFound: false, entryMatchesCurrent: false)
        }
    }

    // MARK: - Command running

    struct CommandResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    protocol CommandRunner: Sendable {
        func run(executablePath: String, arguments: [String]) async throws -> CommandResult
    }

    struct ProcessCommandRunner: CommandRunner {
        func run(executablePath: String, arguments: [String]) async throws -> CommandResult {
            try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                // Node-managed host CLIs often rely on an `env node` shebang.
                // GUI launches lack the shell PATH, so the CLI's own directory
                // (which holds node for NVM installs) leads the child PATH.
                var environment = ProcessInfo.processInfo.environment
                let cliDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
                let inherited = environment["PATH"] ?? ""
                if !inherited.split(separator: ":").map(String.init).contains(cliDirectory) {
                    environment["PATH"] = inherited.isEmpty ? cliDirectory : "\(cliDirectory):\(inherited)"
                }
                process.environment = environment
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                try process.run()
                process.waitUntilExit()
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
            }.value
        }
    }

    // MARK: - Errors

    enum InstallerError: LocalizedError, Equatable {
        case helperMissing(String)
        case hostCLIMissing(String)
        case commandFailed(host: String, detail: String)
        case invalidSettings(path: String)
        case invalidHooksFile(path: String)
        case invalidCodexConfig(path: String)
        case verificationFailed(host: String)
        case timedOut(host: String)

        var errorDescription: String? {
            switch self {
            case .helperMissing(let path):
                return "DictaFlow helper not found at \(path). Reinstall the app, then try again."
            case .hostCLIMissing(let host):
                return "\(host) was not found on this Mac, so automatic setup cannot run. Install the host CLI first, or use the manual setup below."
            case .commandFailed(let host, let detail):
                return "\(host) setup failed: \(detail) You can still use the manual setup below."
            case .invalidSettings(let path):
                return "Muse settings at \(path) is not valid JSON. Fix or move it aside, then try again."
            case .invalidHooksFile(let path):
                return "The hooks file at \(path) is not valid JSON, so DictaFlow hooks were not changed. Fix or move it aside, then try again."
            case .invalidCodexConfig(let path):
                return "The Codex config at \(path) could not be safely updated with DictaFlow tool pre-approval, so it was left unchanged. In Codex, choose Always allow when prompted for DictaFlow tools."
            case .verificationFailed(let host):
                return "\(host) ran but the entry could not be verified. Start a new session; if tools are missing, use the manual setup below."
            case .timedOut(let host):
                return "\(host) setup timed out. Try again, or use the manual setup below."
            }
        }
    }

    // MARK: - Arguments

    static func serverArguments(appID: String, installationID: UUID, host: Host) -> [String] {
        ["--app-id", appID, "--installation-id", installationID.uuidString, "--host", host.hostFlag]
    }

    static func museSettingsURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".config/muse/settings.json")
    }

    /// User-level Codex hooks file documented at learn.chatgpt.com/docs/hooks.
    static func codexHooksURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".codex/hooks.json")
    }

    /// User-level Codex configuration file. `codex mcp add` registers the
    /// server here, and Codex's own Always-allow persists per-tool approvals
    /// under the server's table in this same file.
    static func codexConfigURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".codex/config.toml")
    }

    /// User-level Claude Code settings file documented at code.claude.com/docs/en/hooks.
    static func claudeSettingsURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL.appendingPathComponent(".claude/settings.json")
    }

    static func defaultHomeDirectoryURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }

    // MARK: - Status

    static func refreshState(host: Host, executable: String, appID: String, installationID: UUID,
                             runner: any CommandRunner = ProcessCommandRunner(),
                             homeDirectoryURL: URL? = nil,
                             cliDiscovery: @Sendable (Host) -> String? = { AgentVoiceHostAvailability.check($0).foundCLI }) async -> HostState {
        let cliPath = cliDiscovery(host)
        let home = homeDirectoryURL ?? defaultHomeDirectoryURL()
        let arguments = serverArguments(appID: appID, installationID: installationID, host: host)
        switch host {
        case .other:
            return .manualOnly(cliPath: cliPath)
        case .codex:
            guard let cliPath else { return HostState(cliPath: nil, configuredEntryFound: false, entryMatchesCurrent: false) }
            guard let output = try? await withTimeout(seconds: 30, host: host.name, operation: {
                try await runner.run(executablePath: cliPath, arguments: ["mcp", "get", "--json", "dictaflow"])
            }) else { return HostState(cliPath: cliPath, configuredEntryFound: false, entryMatchesCurrent: false) }
            guard output.exitCode == 0 else {
                return HostState(cliPath: cliPath, configuredEntryFound: false, entryMatchesCurrent: false)
            }
            let matches = codexEntryMatches(json: Data(output.stdout.utf8), executable: executable, arguments: arguments)
            return withHookStatus(HostState(cliPath: cliPath, configuredEntryFound: true, entryMatchesCurrent: matches),
                                  host: host, homeDirectoryURL: home)
        case .claudeCode:
            guard let cliPath else { return HostState(cliPath: nil, configuredEntryFound: false, entryMatchesCurrent: false) }
            guard let output = try? await withTimeout(seconds: 30, host: host.name, operation: {
                try await runner.run(executablePath: cliPath, arguments: ["mcp", "get", "dictaflow"])
            }) else { return HostState(cliPath: cliPath, configuredEntryFound: false, entryMatchesCurrent: false) }
            guard output.exitCode == 0 else {
                return HostState(cliPath: cliPath, configuredEntryFound: false, entryMatchesCurrent: false)
            }
            let matches = claudeOutputMatches(output: output.stdout, executable: executable, installationID: installationID)
            return withHookStatus(HostState(cliPath: cliPath, configuredEntryFound: true, entryMatchesCurrent: matches),
                                  host: host, homeDirectoryURL: home)
        case .museCode:
            let url = museSettingsURL(homeDirectoryURL: home)
            let data = try? Data(contentsOf: url)
            let (found, matches) = museEntryStatus(data: data, executable: executable, arguments: arguments)
            return HostState(cliPath: cliPath, configuredEntryFound: found, entryMatchesCurrent: matches)
        }
    }

    // MARK: - Setup

    @discardableResult
    static func setUp(host: Host, executable: String, appID: String, installationID: UUID,
                      agentVoiceEnabled: Bool, runner: any CommandRunner = ProcessCommandRunner(),
                      homeDirectoryURL: URL? = nil,
                      cliDiscovery: @Sendable (Host) -> String? = { AgentVoiceHostAvailability.check($0).foundCLI }) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw InstallerError.helperMissing(executable)
        }
        let home = homeDirectoryURL ?? defaultHomeDirectoryURL()
        let arguments = serverArguments(appID: appID, installationID: installationID, host: host)
        var codexApproval: CodexApprovalMerge?
        switch host {
        case .other:
            throw InstallerError.commandFailed(host: host.name, detail: "Manual setup only.")
        case .codex:
            let cli = try requireCLI(for: host, discovery: cliDiscovery)
            let result = try await withTimeout(seconds: 60, host: host.name, operation: {
                try await runner.run(executablePath: cli, arguments: ["mcp", "add", "dictaflow", "--", executable] + arguments)
            })
            guard result.exitCode == 0 else {
                throw InstallerError.commandFailed(host: host.name, detail: nonempty(result.stderr, fallback: result.stdout))
            }
            guard await isCodexConfigured(executable: executable, arguments: arguments, cliPath: cli, runner: runner) else {
                throw InstallerError.verificationFailed(host: host.name)
            }
            try writeHooks(host: host, homeDirectoryURL: home)
            guard hooksStatus(data: try? Data(contentsOf: codexHooksURL(homeDirectoryURL: home)), host: host).matches else {
                throw InstallerError.verificationFailed(host: host.name)
            }
            let configURL = codexConfigURL(homeDirectoryURL: home)
            let originalConfig = try? Data(contentsOf: configURL)
            codexApproval = try writeCodexApproval(homeDirectoryURL: home)
            if case .applied = codexApproval {
                // The `mcp add` success above proves the file parsed before
                // our edit. Any gate failure, a bad exit or a timeout,
                // restores the untouched bytes so setup never strands a
                // broken Codex config.
                do {
                    let list = try await withTimeout(seconds: 30, host: host.name, operation: {
                        try await runner.run(executablePath: cli, arguments: ["mcp", "list"])
                    })
                    guard list.exitCode == 0 else {
                        throw InstallerError.invalidCodexConfig(path: configURL.path)
                    }
                } catch {
                    if let originalConfig { try? originalConfig.write(to: configURL, options: .atomic) }
                    throw error
                }
            }
        case .claudeCode:
            let cli = try requireCLI(for: host, discovery: cliDiscovery)
            // Remove-then-add: adding over an existing server reports "already exists".
            _ = try? await withTimeout(seconds: 60, host: host.name, operation: {
                try await runner.run(executablePath: cli, arguments: ["mcp", "remove", "dictaflow", "-s", "user"])
            })
            let result = try await withTimeout(seconds: 60, host: host.name, operation: {
                try await runner.run(executablePath: cli,
                                     arguments: ["mcp", "add", "--transport", "stdio", "dictaflow", "-s", "user",
                                                 "--", executable] + arguments)
            })
            guard result.exitCode == 0, !result.stdout.contains("already exists") else {
                let detail = result.stdout.contains("already exists")
                    ? "the entry already exists and could not be replaced"
                    : nonempty(result.stderr, fallback: result.stdout)
                throw InstallerError.commandFailed(host: host.name, detail: detail)
            }
            guard await isClaudeConfigured(executable: executable, installationID: installationID,
                                           cliPath: cli, runner: runner) else {
                throw InstallerError.verificationFailed(host: host.name)
            }
            try writeHooks(host: host, homeDirectoryURL: home)
            guard hooksStatus(data: try? Data(contentsOf: claudeSettingsURL(homeDirectoryURL: home)), host: host).matches else {
                throw InstallerError.verificationFailed(host: host.name)
            }
        case .museCode:
            try writeMuseSettings(executable: executable, arguments: arguments, homeDirectoryURL: home)
            let data = try? Data(contentsOf: museSettingsURL(homeDirectoryURL: home))
            let (_, matches) = museEntryStatus(data: data, executable: executable, arguments: arguments)
            guard matches else { throw InstallerError.verificationFailed(host: host.name) }
        }
        var message = "\(host.name) setup complete."
        switch host {
        case .codex:
            message += " DictaFlow hooks were added to ~/.codex/hooks.json alongside the server. Open /hooks in Codex and review and trust the three DictaFlow hooks. Start a new Codex session so it picks up the server."
            switch codexApproval {
            case .applied:
                message += " DictaFlow's own tools are pre-approved in ~/.codex/config.toml, so Codex will not prompt for them."
            case .alreadyApproved:
                message += " DictaFlow tool approval in ~/.codex/config.toml is already set and was left untouched; Codex honors that value."
            case .noServerEntry:
                message += " The DictaFlow server entry was not found in ~/.codex/config.toml, so tool pre-approval was skipped. In Codex, choose Always allow when prompted for DictaFlow tools."
            case .none:
                break
            }
        case .claudeCode:
            message += " DictaFlow hooks were added to ~/.claude/settings.json alongside your other settings. Start a new Claude Code session so it picks up the server and hooks."
        default:
            message += " Start a new \(host.name) session so it picks up the server."
        }
        if !agentVoiceEnabled {
            message += " Turn Enable Agent Voice on above; the server needs it."
        }
        return message
    }

    // MARK: - Verification helpers

    static func codexEntryMatches(json: Data, executable: String, arguments: [String]) -> Bool {
        struct Transport: Decodable { var command: String; var args: [String]? }
        struct Entry: Decodable { var transport: Transport }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: json) else { return false }
        guard entry.transport.command == executable else { return false }
        return entry.transport.args == arguments
    }

    static func claudeOutputMatches(output: String, executable: String, installationID: UUID) -> Bool {
        output.contains(executable) && output.contains(installationID.uuidString)
    }

    static func museEntryStatus(data: Data?, executable: String, arguments: [String]) -> (found: Bool, matches: Bool) {
        guard let data, !data.isEmpty else { return (false, false) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcp_servers"] as? [String: Any],
              let entry = servers["dictaflow"] as? [String: Any] else { return (false, false) }
        guard (entry["command"] as? String) == executable,
              (entry["args"] as? [String]) == arguments else { return (true, false) }
        return (true, true)
    }

    static func mergedMuseSettings(existing: Data?, executable: String, arguments: [String]) throws -> Data {
        var json: [String: Any]
        if let existing, !existing.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw InstallerError.invalidSettings(path: museSettingsURL(homeDirectoryURL: defaultHomeDirectoryURL()).path)
            }
            json = parsed
        } else {
            json = [:]
        }
        var servers = json["mcp_servers"] as? [String: Any] ?? [:]
        servers["dictaflow"] = ["transport": "stdio", "command": executable, "args": arguments, "mode": "optional"]
        json["mcp_servers"] = servers
        if json["schema_version"] == nil { json["schema_version"] = 1 }
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Native lifecycle hooks

    /// Events with a documented DictaFlow hook, per host. Codex documents
    /// UserPromptSubmit, Stop, and Interrupt with a Codex-specific turn_id.
    /// Claude Code documents UserPromptSubmit and Stop with session_id only
    /// and has no Interrupt event, so none is invented for it. Muse Code
    /// documents no lifecycle hooks; it stays MCP-only.
    static func expectedHookEvents(for host: Host) -> [String] {
        switch host {
        case .codex: ["UserPromptSubmit", "Stop", "Interrupt"]
        case .claudeCode: ["UserPromptSubmit", "Stop"]
        case .museCode, .other: []
        }
    }

    /// The exact handler DictaFlow installs for one event. Identity of our
    /// own hooks in a file is `type == mcp_tool && server == dictaflow`;
    /// setup replaces those with this exact definition and keeps every
    /// other handler untouched. The prompt text is captured only from the
    /// hook's explicit `prompt` payload field, never from a transcript.
    static func expectedHookHandler(for host: Host, event: String) -> [String: Any]? {
        let tool: String
        let input: [String: Any]
        switch (host, event) {
        case (.codex, "UserPromptSubmit"):
            tool = "on_user_prompt_submit"
            input = ["session_id": "${session_id}", "turn_id": "${turn_id}", "prompt": "${prompt}"]
        case (.codex, "Stop"):
            tool = "on_stop"
            input = ["session_id": "${session_id}", "turn_id": "${turn_id}"]
        case (.codex, "Interrupt"):
            tool = "on_interrupt"
            input = ["session_id": "${session_id}", "turn_id": "${turn_id}"]
        case (.claudeCode, "UserPromptSubmit"):
            tool = "on_user_prompt_submit"
            input = ["session_id": "${session_id}", "prompt": "${prompt}"]
        case (.claudeCode, "Stop"):
            tool = "on_stop"
            input = ["session_id": "${session_id}"]
        default: return nil
        }
        // `statusMessage` is the label Codex shows for the handler in /hooks
        // review (and while it runs) instead of "Unnamed hook". The JSON key is
        // camelCase per Codex's own handler schema. There is no `name` field:
        // unknown keys are tolerated but never displayed. Identification still
        // uses type + server only.
        return ["type": "mcp_tool", "server": "dictaflow", "tool": tool, "input": input,
                "timeout": 2, "statusMessage": "DictaFlow: Agent Voice"]
    }

    static func hooksStatus(data: Data?, host: Host) -> (found: Bool, matches: Bool) {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return (false, false) }
        var found = false
        var matches = !expectedHookEvents(for: host).isEmpty
        for event in expectedHookEvents(for: host) {
            let handlers = hookHandlers(in: hooks[event])
            let own = handlers.filter(isDictaFlowHook)
            if !own.isEmpty { found = true }
            guard let expected = expectedHookHandler(for: host, event: event),
                  own.count == 1, canonicalJSON(own[0]) == canonicalJSON(expected) else {
                matches = false
                continue
            }
        }
        // A stale DictaFlow handler under an event we no longer install
        // (for example Interrupt on Claude Code) also means not current.
        for (event, groups) in hooks where !expectedHookEvents(for: host).contains(event) {
            if hookHandlers(in: groups).contains(where: isDictaFlowHook) { found = true; matches = false }
        }
        return (found, matches && found)
    }

    /// Merges DictaFlow hooks into a Codex `hooks.json` root object,
    /// preserving other top-level keys, events, groups, and handlers.
    static func mergedCodexHooks(existing: Data?) throws -> Data {
        try mergedHooksData(existing: existing, host: .codex,
                            path: codexHooksURL(homeDirectoryURL: defaultHomeDirectoryURL()).path)
    }

    /// Merges DictaFlow hooks into Claude Code `settings.json`, preserving
    /// every other setting and hook.
    static func mergedClaudeSettings(existing: Data?) throws -> Data {
        try mergedHooksData(existing: existing, host: .claudeCode,
                            path: claudeSettingsURL(homeDirectoryURL: defaultHomeDirectoryURL()).path)
    }

    private static func mergedHooksData(existing: Data?, host: Host, path: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw InstallerError.invalidHooksFile(path: path)
            }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Remove our own handlers everywhere first, so stale definitions
        // under events we no longer use cannot linger.
        for event in Array(hooks.keys) {
            hooks[event] = groupsWithoutDictaFlow(in: hooks[event])
        }
        for event in expectedHookEvents(for: host) {
            guard let handler = expectedHookHandler(for: host, event: event) else { continue }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [handler]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func hookHandlers(in groupsValue: Any?) -> [[String: Any]] {
        guard let groups = groupsValue as? [[String: Any]] else { return [] }
        return groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    private static func groupsWithoutDictaFlow(in groupsValue: Any?) -> [[String: Any]] {
        guard let groups = groupsValue as? [[String: Any]] else { return [] }
        return groups.compactMap { group in
            var copy = group
            let handlers = (group["hooks"] as? [[String: Any]]) ?? []
            let kept = handlers.filter { handler in !isDictaFlowHook(handler) }
            guard !kept.isEmpty else { return nil }
            copy["hooks"] = kept
            return copy
        }
    }

    private static func isDictaFlowHook(_ handler: [String: Any]) -> Bool {
        (handler["type"] as? String) == "mcp_tool" && (handler["server"] as? String) == "dictaflow"
    }

    private static func canonicalJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func withHookStatus(_ state: HostState, host: Host, homeDirectoryURL: URL) -> HostState {
        var state = state
        let url = host == .codex ? codexHooksURL(homeDirectoryURL: homeDirectoryURL)
            : host == .claudeCode ? claudeSettingsURL(homeDirectoryURL: homeDirectoryURL) : nil
        let status = hooksStatus(data: url.flatMap { try? Data(contentsOf: $0) }, host: host)
        state.hooksEntryFound = status.found
        state.hooksMatchCurrent = status.matches
        return state
    }

    private static func writeHooks(host: Host, homeDirectoryURL: URL) throws {
        let url: URL
        let merged: Data
        switch host {
        case .codex:
            url = codexHooksURL(homeDirectoryURL: homeDirectoryURL)
            merged = try mergedHooksData(existing: try? Data(contentsOf: url), host: host, path: url.path)
        case .claudeCode:
            url = claudeSettingsURL(homeDirectoryURL: homeDirectoryURL)
            merged = try mergedHooksData(existing: try? Data(contentsOf: url), host: host, path: url.path)
        case .museCode, .other: return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try merged.write(to: url, options: .atomic)
    }

    // MARK: - Codex tool pre-approval

    /// Server-level approval that Codex setup writes so the model is not
    /// prompted for DictaFlow's own tools. This mirrors what Codex writes
    /// for a manual Always-allow (`[mcp_servers.<server>.tools.<tool>]
    /// approval_mode = "approve"`), but as one server default covering every
    /// current and future DictaFlow tool, including the read-only status
    /// query the model uses to address the current draft revision.
    static let codexServerTableHeader = "[mcp_servers.dictaflow]"
    static let codexApprovalKey = "default_tools_approval_mode"
    static let codexApprovalValue = "approve"

    enum CodexApprovalMerge: Equatable, Sendable {
        case applied(String)
        case alreadyApproved
        case noServerEntry
    }

    /// Computes the updated `~/.codex/config.toml` text with the server
    /// approval added under `[mcp_servers.dictaflow]`, preserving every
    /// other byte. Never overwrites an existing value, never creates a
    /// second server table, and leaves project-scoped or otherwise
    /// unregistered servers alone (`.noServerEntry`).
    static func mergedCodexApproval(existing: String) throws -> CodexApprovalMerge {
        guard !existing.isEmpty else { return .noServerEntry }
        let newline = existing.contains("\r\n") ? "\r\n" : "\n"
        let lines = existing.components(separatedBy: newline)
        let headerIndexes = lines.indices.filter { isCodexServerTableHeader(lines[$0]) }
        guard headerIndexes.count <= 1 else {
            throw InstallerError.invalidCodexConfig(path: codexConfigURL(homeDirectoryURL: defaultHomeDirectoryURL()).path)
        }
        guard let headerIndex = headerIndexes.first else {
            // A top-level dotted key predating the table form also approves.
            return lines.contains(where: isDottedDictaflowApproval) ? .alreadyApproved : .noServerEntry
        }
        var sectionEnd = lines.count
        for index in (headerIndex + 1)..<lines.count where isTOMLTableHeader(lines[index]) {
            sectionEnd = index
            break
        }
        if lines[headerIndex + 1..<sectionEnd].contains(where: isActiveApprovalKey) {
            return .alreadyApproved
        }
        var updated = lines
        updated.insert("\(codexApprovalKey) = \"\(codexApprovalValue)\"", at: headerIndex + 1)
        return .applied(updated.joined(separator: newline))
    }

    /// Writes the server approval into the user's Codex config. Returns how
    /// the file was handled so setup can report it honestly.
    static func writeCodexApproval(homeDirectoryURL: URL) throws -> CodexApprovalMerge {
        let url = codexConfigURL(homeDirectoryURL: homeDirectoryURL)
        guard let data = try? Data(contentsOf: url),
              let existing = String(data: data, encoding: .utf8) else {
            return .noServerEntry
        }
        switch try mergedCodexApproval(existing: existing) {
        case .applied(let updated):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            do {
                try updated.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw InstallerError.invalidCodexConfig(path: url.path)
            }
            return .applied(updated)
        case .alreadyApproved: return .alreadyApproved
        case .noServerEntry: return .noServerEntry
        }
    }

    private static func isCodexServerTableHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(codexServerTableHeader) else { return false }
        // `[mcp_servers.dictaflow.tools.x]` and `[mcp_servers.dictaflow2]`
        // share the prefix but are different tables.
        let rest = trimmed.dropFirst(codexServerTableHeader.count)
        return rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first == "#"
    }

    private static func isTOMLTableHeader(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    private static func isActiveApprovalKey(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), trimmed.hasPrefix(codexApprovalKey) else { return false }
        let rest = trimmed.dropFirst(codexApprovalKey.count).trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("=")
    }

    private static func isDottedDictaflowApproval(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !isTOMLTableHeader(line) else { return false }
        let pattern = #"mcp_servers\s*\.\s*dictaflow\s*\.\s*default_tools_approval_mode\s*="#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Private

    private static func requireCLI(for host: Host, discovery: @Sendable (Host) -> String?) throws -> String {
        guard let cli = discovery(host) else {
            throw InstallerError.hostCLIMissing(host.name)
        }
        return cli
    }

    private static func isCodexConfigured(executable: String, arguments: [String],
                                          cliPath: String, runner: any CommandRunner) async -> Bool {
        guard let output = try? await withTimeout(seconds: 30, host: "Codex", operation: {
            try await runner.run(executablePath: cliPath, arguments: ["mcp", "get", "--json", "dictaflow"])
        }), output.exitCode == 0 else { return false }
        return codexEntryMatches(json: Data(output.stdout.utf8), executable: executable, arguments: arguments)
    }

    private static func isClaudeConfigured(executable: String, installationID: UUID,
                                           cliPath: String, runner: any CommandRunner) async -> Bool {
        guard let output = try? await withTimeout(seconds: 30, host: "Claude Code", operation: {
            try await runner.run(executablePath: cliPath, arguments: ["mcp", "get", "dictaflow"])
        }), output.exitCode == 0 else { return false }
        return claudeOutputMatches(output: output.stdout, executable: executable, installationID: installationID)
    }

    private static func writeMuseSettings(executable: String, arguments: [String], homeDirectoryURL: URL) throws {
        let url = museSettingsURL(homeDirectoryURL: homeDirectoryURL)
        let existing = try? Data(contentsOf: url)
        if let existing, !existing.isEmpty,
           (try? JSONSerialization.jsonObject(with: existing) as? [String: Any]) == nil {
            throw InstallerError.invalidSettings(path: url.path)
        }
        let merged = try mergedMuseSettings(existing: existing, executable: executable, arguments: arguments)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try merged.write(to: url, options: .atomic)
    }

    private static func withTimeout<T: Sendable>(seconds: UInt64, host: String,
                                                 operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw InstallerError.timedOut(host: host)
            }
            guard let result = try await group.next() else { throw InstallerError.timedOut(host: host) }
            group.cancelAll()
            return result
        }
    }

    private static func nonempty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackTrimmed.isEmpty ? "unknown error" : fallbackTrimmed
    }
}
