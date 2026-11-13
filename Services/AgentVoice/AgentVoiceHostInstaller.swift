import Darwin
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
        var entryDisabled: Bool = false

        var hooksConfigured: Bool { hooksEntryFound && hooksMatchCurrent }

        enum Status: Equatable, Sendable {
            case manualOnly
            case notFound
            case foundNotConfigured
            case configured
            case disabled
        }

        var status: Status {
            if entryDisabled { return .disabled }
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
            try Task.checkCancellation()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            // GUI launches may need the CLI's own directory to find node.
            var environment = ProcessInfo.processInfo.environment
            let cliDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
            let inherited = environment["PATH"] ?? ""
            if !inherited.split(separator: ":").contains(Substring(cliDirectory)) {
                environment["PATH"] = inherited.isEmpty ? cliDirectory : "\(cliDirectory):\(inherited)"
            }
            process.environment = environment

            // Independent files let both streams drain as the CLI runs, and
            // descendants holding the descriptors open cannot delay completion.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let out = directory.appendingPathComponent("stdout")
            let err = directory.appendingPathComponent("stderr")
            try Data().write(to: out)
            try Data().write(to: err)
            let stdout = try FileHandle(forUpdating: out)
            defer { try? stdout.close() }
            let stderr = try FileHandle(forUpdating: err)
            defer { try? stderr.close() }
            process.standardOutput = stdout
            process.standardError = stderr
            try Task.checkCancellation()
            try process.run()
            do {
                while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
                try Task.checkCancellation()
            } catch {
                if process.isRunning {
                    let pid = process.processIdentifier
                    let target = getpgid(pid) == pid ? -pid : pid
                    _ = kill(target, SIGTERM)
                    // The calling task is cancelled. Give the CLI a grace period,
                    // then observe its exit before returning to setup or rollback.
                    await Task.detached {
                        try? await Task.sleep(for: .milliseconds(200))
                        if target < 0 || process.isRunning { _ = kill(target, SIGKILL) }
                        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
                        while process.isRunning, ContinuousClock.now < deadline {
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                    }.value
                }
                throw error
            }
            try stdout.seek(toOffset: 0)
            try stderr.seek(toOffset: 0)
            let outputLimit = 2 * 1024 * 1024
            return CommandResult(exitCode: process.terminationStatus,
                                 stdout: String(decoding: try stdout.read(upToCount: outputLimit) ?? Data(), as: UTF8.self),
                                 stderr: String(decoding: try stderr.read(upToCount: outputLimit) ?? Data(), as: UTF8.self))
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
        case codexRollbackConflict(path: String)
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
            case .codexRollbackConflict(let path):
                return "Codex could not verify tool pre-approval. DictaFlow could not safely restore the earlier config at \(path). Review it before trying again."
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

    /// Resolves the effective Codex home, honoring an explicit override or `CODEX_HOME`.
    private static func codexDirectoryURL(homeDirectoryURL: URL?, codexHome: String?) -> URL {
        // An explicit home is isolated from the running app's environment.
        let override = codexHome ?? (homeDirectoryURL == nil ? ProcessInfo.processInfo.environment["CODEX_HOME"] : nil)
        if let override, !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL }
        return (homeDirectoryURL ?? defaultHomeDirectoryURL()).appendingPathComponent(".codex", isDirectory: true)
    }

    /// User-level Codex hooks file documented at learn.chatgpt.com/docs/hooks.
    static func codexHooksURL(homeDirectoryURL: URL? = nil, codexHome: String? = nil) -> URL {
        codexDirectoryURL(homeDirectoryURL: homeDirectoryURL, codexHome: codexHome).appendingPathComponent("hooks.json")
    }

    /// User-level Codex configuration file. `codex mcp add` registers the
    /// server here, and Codex's own Always-allow persists per-tool approvals
    /// under the server's table in this same file.
    static func codexConfigURL(homeDirectoryURL: URL? = nil, codexHome: String? = nil) -> URL {
        codexDirectoryURL(homeDirectoryURL: homeDirectoryURL, codexHome: codexHome).appendingPathComponent("config.toml")
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
                                  host: host, url: codexHooksURL(homeDirectoryURL: homeDirectoryURL))
        case .claudeCode:
            guard let cliPath else { return HostState(cliPath: nil, configuredEntryFound: false, entryMatchesCurrent: false) }
            guard let output = try? await withTimeout(seconds: 30, host: host.name, operation: {
                try await runner.run(executablePath: cliPath, arguments: ["mcp", "get", "dictaflow"])
            }) else { return HostState(cliPath: cliPath, configuredEntryFound: false, entryMatchesCurrent: false) }
            guard output.exitCode == 0 else {
                return HostState(cliPath: cliPath, configuredEntryFound: false, entryMatchesCurrent: false)
            }
            let matches = claudeOutputMatches(output: output.stdout, executable: executable, arguments: arguments)
            return withHookStatus(HostState(cliPath: cliPath, configuredEntryFound: true, entryMatchesCurrent: matches),
                                  host: host, url: claudeSettingsURL(homeDirectoryURL: home))
        case .museCode:
            let url = museSettingsURL(homeDirectoryURL: home)
            let data = try? Data(contentsOf: url)
            let entry = museEntryStatus(data: data, executable: executable, arguments: arguments)
            return HostState(cliPath: cliPath, configuredEntryFound: entry.found, entryMatchesCurrent: entry.matches, entryDisabled: entry.disabled)
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
        let codexHooks = codexHooksURL(homeDirectoryURL: homeDirectoryURL)
        let codexConfig = codexConfigURL(homeDirectoryURL: homeDirectoryURL)
        var codexApproval: CodexApprovalMerge?
        var museDisabled = false
        switch host {
        case .other:
            throw InstallerError.commandFailed(host: host.name, detail: "Manual setup only.")
        case .codex:
            let cli = try requireCLI(for: host, discovery: cliDiscovery)
            _ = try mergedHooksData(existing: readIfPresent(codexHooks), host: host, path: codexHooks.path)
            let result = try await withTimeout(seconds: 60, host: host.name, operation: {
                try await runner.run(executablePath: cli, arguments: ["mcp", "add", "dictaflow", "--", executable] + arguments)
            })
            guard result.exitCode == 0 else {
                throw InstallerError.commandFailed(host: host.name, detail: nonempty(result.stderr, fallback: result.stdout))
            }
            guard await isCodexConfigured(executable: executable, arguments: arguments, cliPath: cli, runner: runner) else {
                throw InstallerError.verificationFailed(host: host.name)
            }
            try writeHooks(host: host, url: codexHooks)
            guard hooksStatus(data: try Data(contentsOf: codexHooks), host: host).matches else {
                throw InstallerError.verificationFailed(host: host.name)
            }
            let originalConfig = try readIfPresent(codexConfig)
            codexApproval = try writeCodexApproval(original: originalConfig, to: codexConfig)
            if case .applied(let updated) = codexApproval, let originalConfig {
                // The `mcp add` success above proves the file parsed before
                // our edit. A failed check restores that snapshot only
                // if the current file still contains exactly our edit.
                do {
                    let list = try await withTimeout(seconds: 30, host: host.name, operation: {
                        try await runner.run(executablePath: cli, arguments: ["mcp", "list"])
                    })
                    guard list.exitCode == 0 else {
                        throw InstallerError.invalidCodexConfig(path: codexConfig.path)
                    }
                } catch {
                    do {
                        guard try readIfPresent(codexConfig) == Data(updated.utf8) else {
                            throw InstallerError.codexRollbackConflict(path: codexConfig.path)
                        }
                        try originalConfig.write(to: codexConfig, options: .atomic)
                    } catch {
                        throw InstallerError.codexRollbackConflict(path: codexConfig.path)
                    }
                    throw error
                }
            }
        case .claudeCode:
            let cli = try requireCLI(for: host, discovery: cliDiscovery)
            let version = try await withTimeout(seconds: 30, host: host.name) {
                try await runner.run(executablePath: cli, arguments: ["--version"])
            }
            guard version.exitCode == 0, supportsClaudeHooks(version.stdout) else {
                throw InstallerError.commandFailed(host: host.name, detail: "Update Claude Code to 2.1.118 or later to install Agent Voice hooks.")
            }
            let settingsURL = claudeSettingsURL(homeDirectoryURL: home)
            _ = try mergedHooksData(existing: readIfPresent(settingsURL), host: host, path: settingsURL.path)
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
            guard await isClaudeConfigured(executable: executable, arguments: arguments,
                                           cliPath: cli, runner: runner) else {
                throw InstallerError.verificationFailed(host: host.name)
            }
            try writeHooks(host: host, url: settingsURL)
            guard hooksStatus(data: try Data(contentsOf: settingsURL), host: host).matches else {
                throw InstallerError.verificationFailed(host: host.name)
            }
        case .museCode:
            try writeMuseSettings(executable: executable, arguments: arguments, homeDirectoryURL: home)
            let data = try? Data(contentsOf: museSettingsURL(homeDirectoryURL: home))
            let entry = museEntryStatus(data: data, executable: executable, arguments: arguments)
            guard entry.matches else { throw InstallerError.verificationFailed(host: host.name) }
            museDisabled = entry.disabled
        }
        if museDisabled {
            return "Muse Code settings updated. The DictaFlow server is still disabled. Enable it in Muse Code settings before starting a new session."
        }
        var message = "\(host.name) setup complete."
        switch host {
        case .codex:
            message += " DictaFlow hooks were added to \(codexHooks.path) alongside the server. Open /hooks in Codex and review and trust the three DictaFlow hooks. Start a new Codex session so it picks up the server."
            switch codexApproval {
            case .applied:
                message += " DictaFlow's own tools are pre-approved in \(codexConfig.path), so Codex will not prompt for them."
            case .alreadyApproved:
                message += " DictaFlow tool approval in \(codexConfig.path) is already set and was left untouched; Codex honors that value."
            case .noServerEntry:
                message += " The DictaFlow server entry was not found in \(codexConfig.path), so tool pre-approval was skipped. In Codex, choose Always allow when prompted for DictaFlow tools."
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

    /// Checks that `mcp get` output names the exact helper command and arguments.
    static func claudeOutputMatches(output: String, executable: String, arguments: [String]) -> Bool {
        let lines = Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return lines.contains("Command: \(executable)") && lines.contains("Args: \(arguments.joined(separator: " "))")
    }

    /// Reports whether a Claude Code version string supports hooks (2.1.118 or later).
    private static func supportsClaudeHooks(_ output: String) -> Bool {
        guard let version = output.split(whereSeparator: \.isWhitespace).first else { return false }
        let fields = version.split(separator: ".").compactMap { Int($0) }
        return fields.count == 3 && !fields.lexicographicallyPrecedes([2, 1, 118])
    }

    /// Reads the DictaFlow server entry, reporting whether it exists, matches, or is disabled.
    static func museEntryStatus(data: Data?, executable: String, arguments: [String]) -> (found: Bool, matches: Bool, disabled: Bool) {
        guard let data, !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = (json["mcp_servers"] ?? json["mcpServers"]) as? [String: Any],
              let entry = servers["dictaflow"] as? [String: Any] else { return (false, false, false) }
        let matches = (entry["command"] as? String) == executable && (entry["args"] as? [String]) == arguments
            && (entry["transport"] ?? entry["type"]) as? String == "stdio"
        return (true, matches, (entry["enabled"] as? Bool) == false)
    }

    /// Merges the DictaFlow server into Muse settings, preserving the existing `enabled` flag.
    static func mergedMuseSettings(existing: Data?, executable: String, arguments: [String],
                                   path: String = museSettingsURL(homeDirectoryURL: defaultHomeDirectoryURL()).path) throws -> Data {
        var json: [String: Any]
        if let existing {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw InstallerError.invalidSettings(path: path)
            }
            json = parsed
        } else {
            json = [:]
        }
        let key = json["mcpServers"] == nil ? "mcp_servers" : "mcpServers"
        guard !(json["mcpServers"] != nil && json["mcp_servers"] != nil),
              json[key] == nil || json[key] is [String: Any] else { throw InstallerError.invalidSettings(path: path) }
        var servers = json[key] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["transport": "stdio", "command": executable, "args": arguments, "mode": "optional"]
        if let previous = servers["dictaflow"] as? [String: Any] {
            entry["enabled"] = previous["enabled"]
        }
        servers["dictaflow"] = entry
        json[key] = servers
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
                            path: codexHooksURL().path)
    }

    /// Merges DictaFlow hooks into Claude Code `settings.json`, preserving
    /// every other setting and hook.
    static func mergedClaudeSettings(existing: Data?) throws -> Data {
        try mergedHooksData(existing: existing, host: .claudeCode,
                            path: claudeSettingsURL(homeDirectoryURL: defaultHomeDirectoryURL()).path)
    }

    private static func mergedHooksData(existing: Data?, host: Host, path: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw InstallerError.invalidHooksFile(path: path)
            }
            root = parsed
        }
        guard root["hooks"] == nil || root["hooks"] is [String: Any] else {
            throw InstallerError.invalidHooksFile(path: path)
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Remove our own handlers everywhere first, so stale definitions
        // under events we no longer use cannot linger.
        for event in Array(hooks.keys) {
            guard let groups = hooks[event] as? [[String: Any]],
                  groups.allSatisfy({ $0["hooks"] is [[String: Any]] }) else {
                throw InstallerError.invalidHooksFile(path: path)
            }
            hooks[event] = groupsWithoutDictaFlow(in: groups)
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

    /// Strips DictaFlow handlers from hook groups, dropping groups left empty.
    private static func groupsWithoutDictaFlow(in groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            var copy = group
            let handlers = (group["hooks"] as? [[String: Any]]) ?? []
            let kept = handlers.filter { handler in !isDictaFlowHook(handler) }
            if kept.count == handlers.count { return group }
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

    /// Attaches hook install status from a settings file to a host state.
    private static func withHookStatus(_ state: HostState, host: Host, url: URL) -> HostState {
        var state = state
        let status = hooksStatus(data: try? Data(contentsOf: url), host: host)
        state.hooksEntryFound = status.found
        state.hooksMatchCurrent = status.matches
        return state
    }

    /// Merges DictaFlow hooks into the host settings file at `url`.
    private static func writeHooks(host: Host, url: URL) throws {
        let merged = try mergedHooksData(existing: readIfPresent(url), host: host, path: url.path)
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
            throw InstallerError.invalidCodexConfig(path: codexConfigURL().path)
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
    private static func writeCodexApproval(original: Data?, to url: URL) throws -> CodexApprovalMerge {
        guard let original else { return .noServerEntry }
        guard let existing = String(data: original, encoding: .utf8) else {
            throw InstallerError.invalidCodexConfig(path: url.path)
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

    /// Verifies via the Claude CLI that the DictaFlow server entry is current.
    private static func isClaudeConfigured(executable: String, arguments: [String],
                                           cliPath: String, runner: any CommandRunner) async -> Bool {
        guard let output = try? await withTimeout(seconds: 30, host: "Claude Code", operation: {
            try await runner.run(executablePath: cliPath, arguments: ["mcp", "get", "dictaflow"])
        }), output.exitCode == 0 else { return false }
        return claudeOutputMatches(output: output.stdout, executable: executable, arguments: arguments)
    }

    private static func writeMuseSettings(executable: String, arguments: [String], homeDirectoryURL: URL) throws {
        let url = museSettingsURL(homeDirectoryURL: homeDirectoryURL)
        let existing = try readIfPresent(url)
        let merged = try mergedMuseSettings(existing: existing, executable: executable, arguments: arguments, path: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try merged.write(to: url, options: .atomic)
    }

    /// Reads a file, returning nil only when it is genuinely missing.
    private static func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    /// Runs an operation with a timeout, cancelling it and throwing when the deadline passes.
    static func withTimeout<T: Sendable>(seconds: UInt64, host: String,
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
