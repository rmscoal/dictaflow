import Darwin
import Foundation

/// Host setup for Agent Voice. Installs and verifies the bundled helper in
/// Codex and Muse Code, and supplies manual setup for Claude Code.
/// Codex and Claude also receive user-level lifecycle hook definitions, and
/// Claude and Muse receive a main-agent-only PreToolUse guard so child
/// agents cannot use Omdo voice tools. A configured entry means the
/// host can find the server, not that a live MCP connection exists: the
/// connection happens inside a new host session.
enum AgentVoiceHostInstaller {
    typealias Host = AgentVoiceHostAvailability.Host

    static let serverAlias = "omdo"
    static let legacyAlias = "dictaflow"

    // MARK: - State

    struct HostState: Equatable, Sendable {
        var cliPath: String?
        var configuredEntryFound: Bool
        var entryMatchesCurrent: Bool
        /// Native hooks in the host's user-level hook file: lifecycle hooks
        /// for Codex and Claude, a main-agent-only tool guard for Claude and
        /// Muse. Always false for hosts without hook support.
        var hooksEntryFound: Bool = false
        var hooksMatchCurrent: Bool = false
        var entryDisabled: Bool = false
        /// The installed host CLI is below the version Agent Voice requires
        /// (Codex 0.156.0 for caller identity). The helper rejects every call
        /// from such a host, so no entry state may report it ready.
        var versionUnsupported: Bool = false
        var legacyEntryFound = false
        var updateInterrupted = false

        var hooksConfigured: Bool { hooksEntryFound && hooksMatchCurrent }

        enum Status: Equatable, Sendable {
            case manualOnly
            case notFound
            case foundNotConfigured
            case configured
            case disabled
            case unsupportedVersion
            case migrationRequired
            case updateInterrupted
        }

        var status: Status {
            if updateInterrupted { return .updateInterrupted }
            if versionUnsupported { return .unsupportedVersion }
            if legacyEntryFound { return .migrationRequired }
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

    nonisolated struct ProcessCommandRunner: CommandRunner {
        var overrides: [String: String] = [:]
        var workingDirectory: URL?

        func run(executablePath: String, arguments: [String]) async throws -> CommandResult {
            try Task.checkCancellation()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            // GUI launches may need the CLI's own directory to find node.
            var environment = ProcessInfo.processInfo.environment.merging(overrides) { _, override in override }
            process.currentDirectoryURL = workingDirectory
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
        case verificationFailed(host: String)
        case timedOut(host: String)

        var errorDescription: String? {
            switch self {
            case .helperMissing(let path):
                return "Omdo helper not found at \(path). Reinstall the app, then try again."
            case .hostCLIMissing(let host):
                return "\(host) was not found on this Mac, so automatic setup cannot run. Install the host CLI first, or use the manual setup below."
            case .commandFailed(let host, let detail):
                return "\(host) setup failed: \(detail) You can still use the manual setup below."
            case .invalidSettings(let path):
                return "The settings at \(path) could not be read safely. Review the JSON and try again."
            case .invalidHooksFile(let path):
                return "The hooks file at \(path) is not valid JSON, so Omdo hooks were not changed. Fix or move it aside, then try again."
            case .verificationFailed(let host):
                return "Omdo could not verify the \(host) configuration. Review the profile or use manual configuration."
            case .timedOut(let host):
                return "\(host) setup timed out. Try again, or use the manual setup below."
            }
        }
    }

    // MARK: - Arguments

    static func serverArguments(appID: String, installationID: UUID, host: Host) -> [String] {
        ["--app-id", appID, "--installation-id", installationID.uuidString, "--host", host.hostFlag]
    }

    static func museSettingsURL(homeDirectoryURL: URL? = nil, configHome: String? = nil) -> URL {
        let override = configHome ?? (homeDirectoryURL == nil ? ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] : nil)
        let root = override.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? (homeDirectoryURL ?? defaultHomeDirectoryURL()).appendingPathComponent(".config", isDirectory: true)
        return root.appendingPathComponent("muse/settings.json")
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

    // MARK: - Status and setup

    private static func migration(for host: Host, home: URL?) -> AgentVoiceHostMigration? {
        let base = home ?? defaultHomeDirectoryURL()
        switch host {
        case .codex:
            let directory = codexDirectoryURL(homeDirectoryURL: home, codexHome: nil).resolvingSymlinksInPath()
            return AgentVoiceHostMigration(host: host, configuration: directory.appendingPathComponent("config.toml"),
                                           hooks: directory.appendingPathComponent("hooks.json"),
                                           applicationSupport: base.appendingPathComponent("Library/Application Support"))
        case .museCode:
            let settings = museSettingsURL(homeDirectoryURL: home)
            let directory = settings.deletingLastPathComponent().resolvingSymlinksInPath()
            return AgentVoiceHostMigration(host: host, configuration: directory.appendingPathComponent(settings.lastPathComponent),
                                           hooks: nil, applicationSupport: base.appendingPathComponent("Library/Application Support"))
        case .claudeCode, .other: return nil
        }
    }

    static func refreshState(host: Host, executable: String, appID: String, installationID: UUID,
                             runner: any CommandRunner = ProcessCommandRunner(),
                             homeDirectoryURL: URL? = nil,
                             cliDiscovery: @Sendable (Host) -> String? = { AgentVoiceHostAvailability.check($0).foundCLI }) async -> HostState {
        let cliPath = cliDiscovery(host)
        var state = HostState(cliPath: cliPath, configuredEntryFound: false, entryMatchesCurrent: false)
        let arguments = serverArguments(appID: appID, installationID: installationID, host: host)
        let migration = migration(for: host, home: homeDirectoryURL)
        if migration?.hasPendingUpdate == true { state.updateInterrupted = true; return state }
        switch host {
        case .other:
            return .manualOnly(cliPath: cliPath)
        case .museCode:
            guard let url = migration?.configuration, let data = try? AgentVoiceHostMigration.read(url) else { return state }
            let entry = museEntryStatus(data: data, executable: executable, arguments: arguments)
            state.configuredEntryFound = entry.found
            state.entryMatchesCurrent = entry.matches
            state.entryDisabled = entry.disabled
            state.legacyEntryFound = museServerAliases(data).contains(legacyAlias)
            return withHookStatus(state, host: host, url: url, executable: executable)
        case .codex, .claudeCode:
            guard let cliPath else { return state }
            let probe = migration.map { scopedRunner(runner, codexDirectory: $0.configuration.deletingLastPathComponent()) } ?? runner
            guard let version = try? await run(probe, cli: cliPath, host: host, args: ["--version"]) else { return state }
            let supported = host == .codex ? supportsCodexIdentity(version.stdout) : supportsClaudeHooks(version.stdout)
            guard version.exitCode == 0, supported else { state.versionUnsupported = true; return state }
            let query = host == .codex ? ["mcp", "get", "--json"] : ["mcp", "get"]
            let legacy = try? await run(probe, cli: cliPath, host: host, args: query + [legacyAlias])
            state.legacyEntryFound = legacy?.exitCode == 0
            guard let current = try? await run(probe, cli: cliPath, host: host, args: query + [serverAlias]),
                  current.exitCode == 0 else { return state }
            state.configuredEntryFound = true
            if host == .codex {
                state.entryMatchesCurrent = codexEntryMatches(json: Data(current.stdout.utf8), executable: executable, arguments: arguments)
                let config = migration.flatMap { try? AgentVoiceHostMigration.read($0.configuration) }
                state.entryDisabled = (try? CodexMCPConfiguration(config).isDisabled(alias: serverAlias)) == true
            } else {
                state.entryMatchesCurrent = claudeOutputMatches(output: current.stdout, executable: executable, arguments: arguments)
            }
            let hooks = migration?.hooks ?? claudeProfileDirectory(homeDirectoryURL).appendingPathComponent("settings.json")
            return withHookStatus(state, host: host, url: hooks, executable: executable)
        }
    }

    static func setUp(host: Host, executable: String, appID: String, installationID: UUID,
                      agentVoiceEnabled: Bool, runner: any CommandRunner = ProcessCommandRunner(),
                      homeDirectoryURL: URL? = nil,
                      cliDiscovery: @Sendable (Host) -> String? = { AgentVoiceHostAvailability.check($0).foundCLI },
                      hostIdle: (@Sendable () async throws -> Bool)? = nil) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw InstallerError.helperMissing(executable) }
        guard let migration = migration(for: host, home: homeDirectoryURL) else { throw AgentVoiceHostMigration.Failure.manual }
        let arguments = serverArguments(appID: appID, installationID: installationID, host: host)
        let config = migration.configuration
        let ownsPath: (String) -> Bool = {
            AgentVoiceHostMigration.isOwnedHelper($0, current: executable, appID: appID)
        }
        var disabled = false
        let cli: String?
        if host == .codex {
            guard let path = cliDiscovery(host) else { throw InstallerError.hostCLIMissing(host.name) }
            let version = try await run(runner, cli: path, host: host, args: ["--version"])
            guard version.exitCode == 0, supportsCodexIdentity(version.stdout) else {
                throw InstallerError.commandFailed(host: host.name, detail: "Update to stable Codex 0.156.0 or later.")
            }
            cli = path
        } else {
            cli = nil
        }
        try await migration.apply(executable: executable, arguments: arguments) {
            let original = try AgentVoiceHostMigration.read(config)
            if let hooks = migration.hooks {
                let configuration = try CodexMCPConfiguration(original)
                let candidate = try configuration.candidate(executable: executable, arguments: arguments, ownsPath: ownsPath)
                let originalHooks = try AgentVoiceHostMigration.read(hooks)
                let root = try configurationObject(originalHooks, path: hooks.path)
                let updated = try migratedHooks(root: root, host: host, executable: executable, ownsPath: ownsPath)
                return [try AgentVoiceHostMigration.change(at: config, original: original, candidate: candidate),
                        try AgentVoiceHostMigration.change(at: hooks, original: originalHooks, candidate: encodeJSON(updated))]
            }
            let candidate = try migratedMuseSettings(original, path: config.path, executable: executable,
                                                     arguments: arguments, ownsPath: ownsPath)
            return [try AgentVoiceHostMigration.change(at: config, original: original, candidate: candidate)]
        } verify: { changes, directory in
            if let cli {
                let isolated = directory.appendingPathComponent("verification-\(UUID().uuidString)")
                try MigrationFiles.makePrivateDirectory(isolated)
                defer { try? FileManager.default.removeItem(at: isolated) }
                let scoped = scopedRunner(runner, codexDirectory: isolated)
                try MigrationFiles.replaceDurably(changes[0].candidate, at: isolated.appendingPathComponent("config.toml"))
                let list = try await run(scoped, cli: cli, host: host, args: ["mcp", "list"])
                let entry = try await run(scoped, cli: cli, host: host, args: ["mcp", "get", "--json", serverAlias])
                let configuration = try CodexMCPConfiguration(changes[0].candidate)
                guard list.exitCode == 0, !configuration.aliases.contains(legacyAlias), entry.exitCode == 0,
                      codexEntryMatches(json: Data(entry.stdout.utf8), executable: executable, arguments: arguments),
                      hooksStatus(data: changes[1].candidate, host: host, executable: executable).matches else {
                    throw InstallerError.verificationFailed(host: host.name)
                }
                disabled = configuration.isDisabled(alias: serverAlias)
            } else {
                let data = changes[0].candidate
                let entry = museEntryStatus(data: data, executable: executable, arguments: arguments)
                guard entry.matches, !museServerAliases(data).contains(legacyAlias),
                      hooksStatus(data: data, host: host, executable: executable).matches else {
                    throw InstallerError.verificationFailed(host: host.name)
                }
                disabled = entry.disabled
            }
        } checkIdle: {
            let idle: Bool
            if let hostIdle { idle = try await hostIdle() }
            else { idle = try await isHostIdle(host) }
            guard idle else { throw AgentVoiceHostMigration.Failure.hostRunning(host.name) }
        }
        if disabled { return "Omdo is configured in \(host.name) and remains disabled in the host settings." }
        var message = "Omdo is configured in \(host.name). Start a new session to use it."
        if host == .codex { message += " In the new session, open /hooks and review and trust the Omdo hooks." }
        if !agentVoiceEnabled { message += " Turn on Enable Agent Voice to use it." }
        return message
    }

    static func claudeProfileDirectory(_ home: URL? = nil) -> URL {
        if home == nil, let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return claudeSettingsURL(homeDirectoryURL: home ?? defaultHomeDirectoryURL()).deletingLastPathComponent()
    }

    private static func scopedRunner(_ runner: any CommandRunner, codexDirectory: URL) -> any CommandRunner {
        guard var process = runner as? ProcessCommandRunner else { return runner }
        process.overrides["CODEX_HOME"] = codexDirectory.path
        process.workingDirectory = URL(fileURLWithPath: "/", isDirectory: true)
        return process
    }

    private static func run(_ runner: any CommandRunner, cli: String, host: Host, args: [String]) async throws -> CommandResult {
        try await withTimeout(seconds: 30, host: host.name) {
            try await runner.run(executablePath: cli, arguments: args)
        }
    }

    private static func isHostIdle(_ host: Host) async throws -> Bool {
        let process = ProcessCommandRunner()
        let names = host == .codex ? "codex|Codex|codex-app-server" : "muse|Muse|muse-code|Muse Code"
        let result = try await run(process, cli: "/usr/bin/pgrep", host: host, args: ["-u", String(getuid()), "-x", names])
        if result.exitCode == 0 { return false }
        if result.exitCode == 1 { return true }
        throw AgentVoiceHostMigration.Failure.manual
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

    /// The direct MCP caller identity pair first shipped in stable Codex 0.156.
    /// Reject unknown/prerelease formats rather than guessing their capabilities.
    static func supportsCodexIdentity(_ output: String) -> Bool {
        let words = output.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, words[0] == "codex-cli" else { return false }
        let components = words[1].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let fields = components.compactMap { Int($0) }
        return fields.count == 3 && !fields.lexicographicallyPrecedes([0, 156, 0])
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
              let entry = servers[serverAlias] as? [String: Any] else { return (false, false, false) }
        let matches = (entry["command"] as? String) == executable && (entry["args"] as? [String]) == arguments
            && (entry["transport"] ?? entry["type"]) as? String == "stdio"
        return (true, matches, (entry["enabled"] as? Bool) == false)
    }

    private static func configurationObject(_ data: Data?, path: String) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.invalidSettings(path: path)
        }
        return root
    }

    private static func encodeJSON(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func museServerAliases(_ data: Data) -> Set<String> {
        guard let root = try? configurationObject(data, path: "") else { return [] }
        let regular = (root["mcp_servers"] as? [String: Any]) ?? [:]
        let alternate = (root["mcpServers"] as? [String: Any]) ?? [:]
        return Set(regular.keys).union(alternate.keys)
    }

    static func migratedMuseSettings(_ original: Data?, path: String, executable: String,
                                    arguments: [String], ownsPath: (String) -> Bool) throws -> Data {
        var root = try configurationObject(original, path: path)
        let key = root["mcpServers"] == nil ? "mcp_servers" : "mcpServers"
        guard !(root["mcp_servers"] != nil && root["mcpServers"] != nil),
              root[key] == nil || root[key] is [String: Any] else { throw InstallerError.invalidSettings(path: path) }
        var entries = (root[key] as? [String: Any]) ?? [:]
        guard entries[legacyAlias] == nil || entries[serverAlias] == nil else { throw AgentVoiceHostMigration.Failure.conflict }
        let existing = entries[legacyAlias] ?? entries[serverAlias]
        var entry: [String: Any]
        if let existing {
            guard let owned = existing as? [String: Any],
                  let command = owned["command"] as? String, ownsPath(command),
                  owned["args"] as? [String] == arguments,
                  (owned["transport"] ?? owned["type"]) as? String == "stdio" else {
                throw AgentVoiceHostMigration.Failure.conflict
            }
            entry = owned
            entry["command"] = executable
        } else {
            entry = ["transport": "stdio", "command": executable, "args": arguments, "mode": "optional"]
        }
        entries.removeValue(forKey: legacyAlias)
        entries[serverAlias] = entry
        root[key] = entries
        if root["schema_version"] == nil { root["schema_version"] = 1 }
        return try encodeJSON(migratedHooks(root: root, host: .museCode, executable: executable, ownsPath: ownsPath))
    }

    private static func migratedHooks(root: [String: Any], host: Host, executable: String,
                                      ownsPath: (String) -> Bool) throws -> [String: Any] {
        let aliases = [legacyAlias, serverAlias]
        var updated = root
        if let existing = root["hooks"] {
            guard let hooks = existing as? [String: Any] else { throw AgentVoiceHostMigration.Failure.unownedHook }
            for (event, groupsValue) in hooks {
                guard let groups = groupsValue as? [[String: Any]] else { throw AgentVoiceHostMigration.Failure.unownedHook }
                for group in groups {
                    guard let handlers = group["hooks"] as? [[String: Any]] else { throw AgentVoiceHostMigration.Failure.unownedHook }
                    let matcher = group["matcher"] as? String
                    let reservedMatcher = aliases.contains { matcher?.contains("mcp__\($0)__") == true }
                    for handler in handlers where isDictaFlowHook(handler) || reservedMatcher {
                        var candidate = handler
                        if let status = candidate.removeValue(forKey: "statusMessage"),
                           !["Omdo: Agent Voice", "DictaFlow: Agent Voice"].contains(status as? String ?? "") {
                            throw AgentVoiceHostMigration.Failure.unownedHook
                        }
                        if let alias = candidate["server"] as? String, aliases.contains(alias), matcher == nil,
                           group.keys.allSatisfy({ $0 == "hooks" }),
                           var template = expectedHookHandler(for: host, event: event) {
                            template.removeValue(forKey: "statusMessage")
                            template["server"] = alias
                            if canonicalJSON(template) == canonicalJSON(candidate) { continue }
                        }
                        if event == "PreToolUse", let matcher, aliases.contains(where: { matcher == "mcp__\($0)__.*" }),
                           group.keys.allSatisfy({ $0 == "hooks" || $0 == "matcher" }),
                           candidate["type"] as? String == "command", let command = candidate["command"] as? String {
                            let tokens = (candidate["args"] as? [String]).map { [command] + $0 } ?? shellTokens(command)
                            if let invoked = tokens.first, ownsPath(invoked),
                               Array(tokens.dropFirst()) == ["--hook-event", "PreToolUse", "--host", host.hostFlag],
                               Set(candidate.keys).isSubset(of: ["type", "command", "args", "timeout"]),
                               candidate["timeout"] == nil || candidate["timeout"] as? Int == 5 { continue }
                        }
                        throw AgentVoiceHostMigration.Failure.unownedHook
                    }
                }
            }
        }
        try applyHooksMerge(to: &updated, host: host, executable: executable, path: "host settings")
        return updated
    }

    // MARK: - Native lifecycle hooks

    /// Events with a documented DictaFlow hook, per host. Codex documents
    /// UserPromptSubmit, Stop, and Interrupt with a Codex-specific turn_id.
    /// Claude Code documents UserPromptSubmit and Stop with session_id only
    /// and has no Interrupt event, so none is invented for it. Both Claude
    /// and Muse document PreToolUse, which carries the main-agent-only
    /// voice guard. Muse documents command hooks only, so it receives the
    /// guard but no lifecycle hooks; its lifecycle stays model-driven
    /// through direct MCP calls, which the same guard filters.
    static func expectedHookEvents(for host: Host) -> [String] {
        switch host {
        case .codex: ["UserPromptSubmit", "Stop", "Interrupt"]
        case .claudeCode: ["UserPromptSubmit", "Stop", "PreToolUse"]
        case .museCode: ["PreToolUse"]
        case .other: []
        }
    }

    /// Matcher selecting every DictaFlow MCP tool for the PreToolUse guard.
    /// Both hosts document the `mcp__<server>__.*` form for this.
    static let omdoToolMatcher = "mcp__omdo__.*"

    /// The matcher DictaFlow installs for one event, or nil for events whose
    /// group carries no matcher. Lifecycle events match every occurrence.
    static func expectedHookMatcher(for host: Host, event: String) -> String? {
        switch (host, event) {
        case (.claudeCode, "PreToolUse"), (.museCode, "PreToolUse"): omdoToolMatcher
        default: nil
        }
    }

    /// The exact handler Omdo installs for one event. Identity of our
    /// own hooks is checked against the current and previously shipped shapes;
    /// setup replaces those with this exact definition and keeps every
    /// other handler untouched. The prompt text is captured only from the
    /// hook's explicit `prompt` payload field, never from a transcript.
    /// Claude inputs also substitute the host-supplied `${agent_id}` so the
    /// helper can reject hook-forwarded child turns; the field is absent in
    /// the main session.
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
            input = ["session_id": "${session_id}", "prompt": "${prompt}", "agent_id": "${agent_id}"]
        case (.claudeCode, "Stop"):
            tool = "on_stop"
            input = ["session_id": "${session_id}", "agent_id": "${agent_id}"]
        default: return nil
        }
        // `statusMessage` is the label Codex shows for the handler in /hooks
        // review (and while it runs) instead of "Unnamed hook". The JSON key is
        // camelCase per Codex's own handler schema. There is no `name` field:
        // unknown keys are tolerated but never displayed. Identification still
        // uses type + server only.
        return ["type": "mcp_tool", "server": serverAlias, "tool": tool, "input": input,
                "timeout": 2, "statusMessage": "Omdo: Agent Voice"]
    }

    /// The exact PreToolUse guard handler for one host. The helper runs once
    /// per DictaFlow tool call and denies child callers from host-supplied
    /// identity; it prints nothing for the main session. Both hosts use
    /// shell form with a quoted executable path: Claude Code added the
    /// exec-form `args` array only in 2.1.139, while setup still supports
    /// 2.1.118 and later, and Muse accepts shell form only. Identity of
    /// our own guard in a file is a `command` handler invoking
    /// `dictaflow-mcp --hook-event`; setup replaces those and keeps every
    /// other handler untouched.
    static func expectedCommandHookHandler(for host: Host, event: String, executable: String) -> [String: Any]? {
        switch (host, event) {
        case (.claudeCode, "PreToolUse"):
            return ["type": "command", "command": claudeGuardCommand(executable: executable),
                    "timeout": 5, "statusMessage": "Omdo: Agent Voice"]
        case (.museCode, "PreToolUse"):
            return ["type": "command", "command": museGuardCommand(executable: executable),
                    "timeout": 5, "statusMessage": "Omdo: Agent Voice"]
        default: return nil
        }
    }

    /// Shell command running the Claude Code PreToolUse guard. Single
    /// source for one-click setup and the manual snippet so the two cannot
    /// drift. Shell form runs on every supported Claude Code release
    /// (2.1.118 and later); the exec-form `args` array needs 2.1.139+.
    static func claudeGuardCommand(executable: String) -> String {
        "\(shellQuoted(executable)) --hook-event PreToolUse --host claude"
    }

    /// Shell command running the Muse PreToolUse guard. Single source for
    /// one-click setup and the manual snippet so the two cannot drift.
    static func museGuardCommand(executable: String) -> String {
        "\(shellQuoted(executable)) --hook-event PreToolUse --host muse"
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// The exact handler Omdo installs for one event, either kind.
    static func expectedAnyHookHandler(for host: Host, event: String, executable: String) -> [String: Any]? {
        expectedHookHandler(for: host, event: event)
            ?? expectedCommandHookHandler(for: host, event: event, executable: executable)
    }

    static func hooksStatus(data: Data?, host: Host, executable: String) -> (found: Bool, matches: Bool) {
        guard let data, !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return (false, false) }
        var found = false
        var matches = !expectedHookEvents(for: host).isEmpty
        for event in expectedHookEvents(for: host) {
            let groups = (hooks[event] as? [[String: Any]]) ?? []
            let expectedMatcher = expectedHookMatcher(for: host, event: event)
            // Our handler counts only under the expected matcher. A copy
            // under another matcher (for example a hand-edited group) is
            // stale: it is found but never matches.
            let own = groups.filter { ($0["matcher"] as? String) == expectedMatcher }
                .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.filter(isDictaFlowHook)
            let stray = groups.filter { ($0["matcher"] as? String) != expectedMatcher }
                .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.filter(isDictaFlowHook)
            if !own.isEmpty || !stray.isEmpty { found = true }
            guard stray.isEmpty,
                  let expected = expectedAnyHookHandler(for: host, event: event, executable: executable),
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
        // Codex installs no command hooks, so the executable is unused.
        try mergedHooksData(existing: existing, host: .codex,
                            path: codexHooksURL().path, executable: "")
    }

    /// Merges DictaFlow hooks into Claude Code `settings.json`, preserving
    /// every other setting and hook.
    static func mergedClaudeSettings(existing: Data?, executable: String) throws -> Data {
        try mergedHooksData(existing: existing, host: .claudeCode,
                            path: claudeSettingsURL(homeDirectoryURL: defaultHomeDirectoryURL()).path,
                            executable: executable)
    }

    private static func mergedHooksData(existing: Data?, host: Host, path: String, executable: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw InstallerError.invalidHooksFile(path: path)
            }
            root = parsed
        }
        try applyHooksMerge(to: &root, host: host, executable: executable, path: path)
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Replaces our own handlers in a parsed hooks root with the exact
    /// current definitions, preserving every other key, event, group, and
    /// handler. Guard groups carry their matcher; lifecycle groups carry none.
    private static func applyHooksMerge(to root: inout [String: Any], host: Host, executable: String, path: String) throws {
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
            guard let handler = expectedAnyHookHandler(for: host, event: event, executable: executable) else { continue }
            var groups = hooks[event] as? [[String: Any]] ?? []
            if let matcher = expectedHookMatcher(for: host, event: event) {
                groups.append(["matcher": matcher, "hooks": [handler]])
            } else {
                groups.append(["hooks": [handler]])
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
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
        if (handler["type"] as? String) == "mcp_tool", [serverAlias, legacyAlias].contains(handler["server"] as? String ?? "") { return true }
        // Our own PreToolUse guard, recognized by invocation shape, not by
        // substrings: the helper executable must be the invoked program and
        // `--hook-event` a separate argument. Shell form quotes the helper
        // path as the first token; a previous revision installed Claude's
        // guard in exec form (`command` naming the helper with `--hook-event`
        // in `args`), which still matches so setup replaces it. Stale paths
        // still match; a command that only mentions both strings (for
        // example a logger line) is not ours and is never stripped.
        guard (handler["type"] as? String) == "command",
              let command = handler["command"] as? String else { return false }
        if let args = handler["args"] as? [String] {
            return isHelperExecutable(command.trimmingCharacters(in: .whitespaces))
                && args.contains("--hook-event")
        }
        let tokens = shellTokens(command)
        guard let invoked = tokens.first, isHelperExecutable(invoked) else { return false }
        return tokens.dropFirst().contains("--hook-event")
    }

    private static func isHelperExecutable(_ token: String) -> Bool {
        token == "dictaflow-mcp" || token.hasSuffix("/dictaflow-mcp")
    }

    /// Splits a shell-form command into tokens, honoring single and double
    /// quotes (including the `'"'"'` escape `shellQuoted` produces), so a
    /// quoted helper path with spaces stays one token.
    private static func shellTokens(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        for character in command {
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                hasCurrent = true
            } else if character == "'" || character == "\"" {
                quote = character
                hasCurrent = true
            } else if character.isWhitespace {
                if hasCurrent { tokens.append(current); current = ""; hasCurrent = false }
            } else {
                current.append(character)
                hasCurrent = true
            }
        }
        if hasCurrent { tokens.append(current) }
        return tokens
    }

    private static func canonicalJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Attaches hook install status from a settings file to a host state.
    private static func withHookStatus(_ state: HostState, host: Host, url: URL, executable: String) -> HostState {
        var state = state
        let status = hooksStatus(data: try? Data(contentsOf: url), host: host, executable: executable)
        state.hooksEntryFound = status.found
        state.hooksMatchCurrent = status.matches
        return state
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

}
