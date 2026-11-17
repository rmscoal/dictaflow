import Foundation
import XCTest
@testable import DictaFlow_Dev

final class AgentVoiceHostInstallerTests: XCTestCase {
    private let executable = "/Applications/DictaFlow Dev.app/Contents/MacOS/dictaflow-mcp"
    private let installation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func arguments(host: AgentVoiceHostAvailability.Host) -> [String] {
        AgentVoiceHostInstaller.serverArguments(appID: "com.dictaflow.dev", installationID: installation, host: host)
    }

    // MARK: - Muse merge

    func testMuseMergeFromEmptyCreatesEntryAndPreservesSchema() throws {
        let data = try AgentVoiceHostInstaller.mergedMuseSettings(
            existing: nil, executable: executable, arguments: arguments(host: .museCode))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        let (found, matches, _) = AgentVoiceHostInstaller.museEntryStatus(
            data: data, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertTrue(found)
        XCTAssertTrue(matches)
    }

    func testMuseMergePreservesOtherKeysAndUpdatesStaleEntry() throws {
        let existing: [String: Any] = [
            "schema_version": 1,
            "provider": "meta",
            "mcp_servers": ["dictaflow": ["transport": "stdio", "command": "/old/path",
                                           "args": ["--stale"], "mode": "optional"]],
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing)
        let merged = try AgentVoiceHostInstaller.mergedMuseSettings(
            existing: existingData, executable: executable, arguments: arguments(host: .museCode))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(json["provider"] as? String, "meta")
        let (found, matches, _) = AgentVoiceHostInstaller.museEntryStatus(
            data: merged, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertTrue(found)
        XCTAssertTrue(matches)
    }

    func testMuseMergeRejectsInvalidJSON() {
        XCTAssertThrowsError(try AgentVoiceHostInstaller.mergedMuseSettings(
            existing: Data("not json".utf8), executable: executable, arguments: arguments(host: .museCode)))
    }

    func testMuseEntryStatusReportsMissingAndStale() {
        let (missingFound, missingMatches, _) = AgentVoiceHostInstaller.museEntryStatus(
            data: nil, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertFalse(missingFound)
        XCTAssertFalse(missingMatches)

        let stale = try? JSONSerialization.data(withJSONObject: ["mcp_servers": ["dictaflow": ["command": "/old"]]])
        let (staleFound, staleMatches, _) = AgentVoiceHostInstaller.museEntryStatus(
            data: stale, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertTrue(staleFound)
        XCTAssertFalse(staleMatches)
    }

    func testMuseUpdateKeepsDisabledEntryDisabled() throws {
        let existing = Data(#"{"mcpServers":{"dictaflow":{"command":"/old","enabled":false}}}"#.utf8)
        let updated = try AgentVoiceHostInstaller.mergedMuseSettings(
            existing: existing, executable: executable, arguments: arguments(host: .museCode))
        let entry = AgentVoiceHostInstaller.museEntryStatus(
            data: updated, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertTrue(entry.found)
        XCTAssertTrue(entry.matches)
        XCTAssertTrue(entry.disabled)
    }

    func testCodexFilePathsUseTheSameOverride() {
        let home = URL(fileURLWithPath: "/tmp/df-fixture-home")
        let override = "/tmp/df-fixture-codex"
        XCTAssertEqual(AgentVoiceHostInstaller.codexHooksURL(homeDirectoryURL: home, codexHome: override).path,
                       override + "/hooks.json")
        XCTAssertEqual(AgentVoiceHostInstaller.codexConfigURL(homeDirectoryURL: home, codexHome: override).path,
                       override + "/config.toml")
        XCTAssertEqual(AgentVoiceHostInstaller.codexConfigURL(homeDirectoryURL: home, codexHome: nil).path,
                       home.path + "/.codex/config.toml")
    }

    // MARK: - Codex and Claude matching

    func testCodexEntryMatchesExactArguments() throws {
        let payload: [String: Any] = ["transport": ["type": "stdio", "command": executable,
                                                    "args": arguments(host: .codex)]]
        let json = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertTrue(AgentVoiceHostInstaller.codexEntryMatches(
            json: json, executable: executable, arguments: arguments(host: .codex)))
        XCTAssertFalse(AgentVoiceHostInstaller.codexEntryMatches(
            json: json, executable: "/other/path", arguments: arguments(host: .codex)))
    }

    func testClaudeOutputMatchesExactCommandAndArguments() {
        let expected = arguments(host: .claudeCode)
        let output = "  Command: \(executable)\n  Args: \(expected.joined(separator: " "))"
        XCTAssertTrue(AgentVoiceHostInstaller.claudeOutputMatches(
            output: output, executable: executable, arguments: expected))
        XCTAssertFalse(AgentVoiceHostInstaller.claudeOutputMatches(
            output: output.replacingOccurrences(of: "com.dictaflow.dev", with: "com.dictaflow"),
            executable: executable, arguments: expected))
        XCTAssertFalse(AgentVoiceHostInstaller.claudeOutputMatches(
            output: output.replacingOccurrences(of: "Command: ", with: "Command: /other/"),
            executable: executable, arguments: expected))
    }

    func testProcessRunnerDrainsBothStreams() async throws {
        let runner = AgentVoiceHostInstaller.ProcessCommandRunner()
        let result = try await AgentVoiceHostInstaller.withTimeout(seconds: 3, host: "Test") {
            try await runner.run(executablePath: "/bin/sh", arguments: [
                "-c", "head -c 131072 /dev/zero; head -c 131072 /dev/zero >&2; exit 7"
            ])
        }
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout.utf8.count, 131_072)
        XCTAssertEqual(result.stderr.utf8.count, 131_072)
    }

    func testProcessRunnerTimeoutKillsCommandThatIgnoresTerminate() async throws {
        let home = try makeHome()
        let pidFile = home.appendingPathComponent("pid")
        let runner = AgentVoiceHostInstaller.ProcessCommandRunner()
        let start = ContinuousClock.now
        do {
            _ = try await AgentVoiceHostInstaller.withTimeout(seconds: 1, host: "Test") {
                try await runner.run(executablePath: "/bin/sh", arguments: [
                    "-c", "trap '' TERM; printf '%s' $$ > \"$1\"; while :; do :; done", "fixture", pidFile.path
                ])
            }
            XCTFail("Expected timeout")
        } catch let error as AgentVoiceHostInstaller.InstallerError {
            XCTAssertEqual(error, .timedOut(host: "Test"))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1, "Setup must observe the CLI exit before returning the timeout.")
    }

    // MARK: - End-to-end setup with a stubbed host CLI

    private struct StubRunner: AgentVoiceHostInstaller.CommandRunner {
        var handlers: [@Sendable (String, [String]) -> AgentVoiceHostInstaller.CommandResult?]
        func run(executablePath: String, arguments: [String]) async throws -> AgentVoiceHostInstaller.CommandResult {
            for handler in handlers {
                if let result = handler(executablePath, arguments) { return result }
            }
            if executablePath == "/bin/codex", arguments == ["--version"] {
                return .init(exitCode: 0, stdout: "codex-cli 0.156.0", stderr: "")
            }
            throw AgentVoiceHostInstaller.InstallerError.commandFailed(host: "stub", detail: "unexpected call \(arguments)")
        }
    }

    private func makeExecutable() throws -> String {
        // The fixture keeps the real helper basename: guard identity in hook
        // files recognizes our own handlers across stale install paths.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dictaflow-mcp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCodexSetUpAddsAndVerifies() async throws {
        let executable = try makeExecutable()
        let expectedArgs = arguments(host: .codex)
        let payload: [String: Any] = ["transport": ["type": "stdio", "command": executable, "args": expectedArgs]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let runner = StubRunner(handlers: [
            { _, args in args.first == "mcp" && args.contains("add")
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: "Added", stderr: "") : nil },
            { _, args in args == ["mcp", "get", "--json", "dictaflow"]
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: json, stderr: "") : nil },
        ])
        let home = try makeHome()
        let message = try await AgentVoiceHostInstaller.setUp(
            host: .codex, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, agentVoiceEnabled: true,
            runner: runner, homeDirectoryURL: home, cliDiscovery: { _ in "/bin/codex" })
        XCTAssertTrue(message.contains("Start a new Codex session"))
        XCTAssertTrue(message.contains("/hooks"))
        let hooksData = try Data(contentsOf: AgentVoiceHostInstaller.codexHooksURL(homeDirectoryURL: home))
        XCTAssertTrue(AgentVoiceHostInstaller.hooksStatus(data: hooksData, host: .codex, executable: executable).matches)
    }

    func testCodexIdentityVersionFloor() {
        for version in ["codex-cli 0.156.0", "codex-cli 0.169.0\n", "codex-cli 1.0.0"] {
            XCTAssertTrue(AgentVoiceHostInstaller.supportsCodexIdentity(version), version)
        }
        for version in ["codex-cli 0.155.0", "codex-cli 0.156.0-alpha.1", "0.169.0", "unknown",
                        "codex-cli 0.156", "codex-cli 0..156.0", "codex-cli 0.156.0 extra"] {
            XCTAssertFalse(AgentVoiceHostInstaller.supportsCodexIdentity(version), version)
        }
    }

    func testCodexUnsupportedVersionStopsBeforeAnyConfigurationChange() async throws {
        let executable = try makeExecutable()
        let home = try makeHome()
        let hooksURL = AgentVoiceHostInstaller.codexHooksURL(homeDirectoryURL: home)
        let configURL = AgentVoiceHostInstaller.codexConfigURL(homeDirectoryURL: home)
        try FileManager.default.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hooks = Data("{\"hooks\":{}}".utf8)
        let config = Data("model = \"keep-me\"\n".utf8)
        try hooks.write(to: hooksURL)
        try config.write(to: configURL)
        let calls = CallLog()
        let runner = StubRunner(handlers: [{ _, args in
            calls.record(args)
            return .init(exitCode: 0, stdout: "codex-cli 0.155.0", stderr: "")
        }])
        do {
            _ = try await AgentVoiceHostInstaller.setUp(host: .codex, executable: executable,
                appID: "com.dictaflow.dev", installationID: installation, agentVoiceEnabled: true,
                runner: runner, homeDirectoryURL: home, cliDiscovery: { _ in "/bin/codex" })
            XCTFail("Unsupported Codex must not write configuration")
        } catch let error as AgentVoiceHostInstaller.InstallerError {
            XCTAssertTrue(error.localizedDescription.contains("0.156.0"))
        }
        XCTAssertEqual(calls.all, [["--version"]])
        XCTAssertEqual(try Data(contentsOf: hooksURL), hooks)
        XCTAssertEqual(try Data(contentsOf: configURL), config)
    }

    private final class CallLog: Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        func record(_ args: [String]) {
            lock.lock()
            calls.append(args)
            lock.unlock()
        }
        var all: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    func testClaudeSetUpRemovesThenAddsAndVerifies() async throws {
        let executable = try makeExecutable()
        let log = CallLog()
        let output = "Command: \(executable)\nArgs: \(arguments(host: .claudeCode).joined(separator: " "))"
        struct RecordingRunner: AgentVoiceHostInstaller.CommandRunner {
            let log: CallLog
            let output: String
            func run(executablePath: String, arguments: [String]) async throws -> AgentVoiceHostInstaller.CommandResult {
                log.record(arguments)
                return AgentVoiceHostInstaller.CommandResult(exitCode: 0,
                    stdout: arguments == ["--version"] ? "2.1.118 (Claude Code)" : output, stderr: "")
            }
        }
        let runner = RecordingRunner(log: log, output: output)
        let home = try makeHome()
        let message = try await AgentVoiceHostInstaller.setUp(
            host: .claudeCode, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, agentVoiceEnabled: false,
            runner: runner, homeDirectoryURL: home, cliDiscovery: { _ in "/bin/claude" })
        let claudeHooks = try Data(contentsOf: AgentVoiceHostInstaller.claudeSettingsURL(homeDirectoryURL: home))
        XCTAssertTrue(AgentVoiceHostInstaller.hooksStatus(data: claudeHooks, host: .claudeCode, executable: executable).matches)
        XCTAssertTrue(message.contains("main-agent-only tool guard"))
        XCTAssertTrue(message.contains("Turn Enable Agent Voice on"))
        XCTAssertEqual(log.all.count, 4)
        XCTAssertEqual(log.all.first, ["--version"])
        XCTAssertEqual(log.all[1], ["mcp", "remove", "dictaflow", "-s", "user"])
        XCTAssertTrue(log.all[2].contains("-s"))
        XCTAssertTrue(log.all[2].contains("add"))
        XCTAssertEqual(log.all.last, ["mcp", "get", "dictaflow"])
    }

    func testOldClaudeDoesNotInstallHooks() async throws {
        let home = try makeHome()
        let log = CallLog()
        let runner = StubRunner(handlers: [{ _, args in
            log.record(args)
            return .init(exitCode: 0, stdout: "2.1.117 (Claude Code)", stderr: "")
        }])
        do {
            _ = try await AgentVoiceHostInstaller.setUp(
                host: .claudeCode, executable: try makeExecutable(), appID: "com.dictaflow.dev",
                installationID: installation, agentVoiceEnabled: true, runner: runner,
                homeDirectoryURL: home, cliDiscovery: { _ in "/bin/claude" })
            XCTFail("Expected setup to reject a CLI without MCP hooks.")
        } catch let error as AgentVoiceHostInstaller.InstallerError {
            XCTAssertTrue(error.localizedDescription.contains("2.1.118"))
        }
        XCTAssertEqual(log.all, [["--version"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            AgentVoiceHostInstaller.claudeSettingsURL(homeDirectoryURL: home).path))
    }

    func testMuseSetUpWritesRealFileInTemporaryHome() async throws {
        let executable = try makeExecutable()
        let home = try makeHome()
        let message = try await AgentVoiceHostInstaller.setUp(
            host: .museCode, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, agentVoiceEnabled: true,
            runner: StubRunner(handlers: []), homeDirectoryURL: home)
        XCTAssertTrue(message.contains("Start a new Muse Code session"))
        XCTAssertTrue(message.contains("tool guard"))
        let data = try Data(contentsOf: AgentVoiceHostInstaller.museSettingsURL(homeDirectoryURL: home))
        let (found, matches, _) = AgentVoiceHostInstaller.museEntryStatus(
            data: data, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertTrue(found)
        XCTAssertTrue(matches)
        XCTAssertTrue(AgentVoiceHostInstaller.hooksStatus(data: data, host: .museCode, executable: executable).matches,
                      "Muse setup must install the PreToolUse guard alongside the server.")
    }

    func testSetUpFailsWhenHelperIsMissing() async {
        do {
            _ = try await AgentVoiceHostInstaller.setUp(
                host: .codex, executable: "/nonexistent/dictaflow-mcp", appID: "com.dictaflow.dev",
                installationID: installation, agentVoiceEnabled: true,
                runner: StubRunner(handlers: []), cliDiscovery: { _ in "/bin/codex" })
            XCTFail("Expected helperMissing")
        } catch let error as AgentVoiceHostInstaller.InstallerError {
            XCTAssertEqual(error, .helperMissing("/nonexistent/dictaflow-mcp"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - Native hooks merge

    func testHookDefinitionsUseOnlyDocumentedFieldsPerHost() {
        XCTAssertEqual(AgentVoiceHostInstaller.expectedHookEvents(for: .codex),
                       ["UserPromptSubmit", "Stop", "Interrupt"])
        XCTAssertEqual(AgentVoiceHostInstaller.expectedHookEvents(for: .claudeCode),
                       ["UserPromptSubmit", "Stop", "PreToolUse"])
        XCTAssertEqual(AgentVoiceHostInstaller.expectedHookEvents(for: .museCode), ["PreToolUse"])
        XCTAssertTrue(AgentVoiceHostInstaller.expectedHookEvents(for: .other).isEmpty)
        let codexPrompt = AgentVoiceHostInstaller.expectedHookHandler(for: .codex, event: "UserPromptSubmit")?["input"] as? [String: String]
        XCTAssertEqual(codexPrompt?["turn_id"], "${turn_id}")
        XCTAssertEqual(codexPrompt?["prompt"], "${prompt}")
        XCTAssertNil(codexPrompt?["agent_id"], "Codex hooks stay unchanged.")
        XCTAssertNil(AgentVoiceHostInstaller.expectedHookHandler(for: .codex, event: "PreToolUse"))
        let claudePrompt = AgentVoiceHostInstaller.expectedHookHandler(for: .claudeCode, event: "UserPromptSubmit")?["input"] as? [String: String]
        XCTAssertEqual(claudePrompt?["prompt"], "${prompt}")
        XCTAssertEqual(claudePrompt?["agent_id"], "${agent_id}")
        XCTAssertNil(claudePrompt?["turn_id"], "Claude Code documents no turn_id; none is invented.")
        XCTAssertNil(AgentVoiceHostInstaller.expectedHookHandler(for: .claudeCode, event: "Interrupt"),
                     "Claude Code documents no Interrupt hook event.")
        XCTAssertNil(AgentVoiceHostInstaller.expectedHookHandler(for: .museCode, event: "UserPromptSubmit"),
                     "Muse Code documents command hooks only; no mcp_tool lifecycle is invented.")
    }

    func testPreToolUseGuardUsesDocumentedMatcherAndFormPerHost() {
        XCTAssertEqual(AgentVoiceHostInstaller.expectedHookMatcher(for: .claudeCode, event: "PreToolUse"),
                       "mcp__dictaflow__.*")
        XCTAssertEqual(AgentVoiceHostInstaller.expectedHookMatcher(for: .museCode, event: "PreToolUse"),
                       "mcp__dictaflow__.*")
        XCTAssertNil(AgentVoiceHostInstaller.expectedHookMatcher(for: .claudeCode, event: "Stop"))
        let claude = AgentVoiceHostInstaller.expectedCommandHookHandler(
            for: .claudeCode, event: "PreToolUse", executable: executable)
        XCTAssertEqual(claude?["type"] as? String, "command")
        XCTAssertEqual(claude?["command"] as? String,
                       "'\(executable)' --hook-event PreToolUse --host claude")
        XCTAssertNil(claude?["args"], "Exec-form args need Claude Code 2.1.139+; setup supports 2.1.118+, so the guard uses shell form.")
        let muse = AgentVoiceHostInstaller.expectedCommandHookHandler(
            for: .museCode, event: "PreToolUse", executable: executable)
        XCTAssertEqual(muse?["type"] as? String, "command")
        XCTAssertEqual(muse?["command"] as? String,
                       "'\(executable)' --hook-event PreToolUse --host muse")
        XCTAssertNil(muse?["args"], "Muse skips handlers with args; the guard uses shell form only.")
        XCTAssertNil(AgentVoiceHostInstaller.expectedCommandHookHandler(for: .codex, event: "PreToolUse", executable: executable),
                     "Codex setup stays unchanged.")
    }

    func testHookHandlersCarryReviewDisplayNames() {
        let events: [(AgentVoiceHostInstaller.Host, String)] = [
            (.codex, "UserPromptSubmit"), (.codex, "Stop"), (.codex, "Interrupt"),
            (.claudeCode, "UserPromptSubmit"), (.claudeCode, "Stop"),
        ]
        for (host, event) in events {
            XCTAssertEqual(AgentVoiceHostInstaller.expectedHookHandler(for: host, event: event)?["statusMessage"] as? String,
                           "DictaFlow: Agent Voice",
                           "\(event) must show the DictaFlow label in host review, not \"Unnamed hook\".")
        }
        for host: AgentVoiceHostInstaller.Host in [.claudeCode, .museCode] {
            XCTAssertEqual(AgentVoiceHostInstaller.expectedCommandHookHandler(
                for: host, event: "PreToolUse", executable: executable)?["statusMessage"] as? String,
                           "DictaFlow: Agent Voice")
        }
    }

    func testCodexHooksMergePreservesOthersAndIsIdempotent() throws {
        let other: [String: Any] = ["type": "command", "command": "/usr/bin/true"]
        let stale: [String: Any] = ["type": "mcp_tool", "server": "dictaflow", "tool": "on_stop",
                                    "input": ["session_id": "${session_id}"], "timeout": 9]
        let existing: [String: Any] = [
            "description": "keep me",
            "hooks": [
                "Stop": [["hooks": [other, stale]]],
                "SessionStart": [["hooks": [other]]],
            ],
        ]
        let first = try AgentVoiceHostInstaller.mergedCodexHooks(existing: JSONSerialization.data(withJSONObject: existing))
        let second = try AgentVoiceHostInstaller.mergedCodexHooks(existing: first)
        XCTAssertEqual(first, second, "Merging twice must not duplicate or reorder our hooks.")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(root["description"] as? String, "keep me")
        let status = AgentVoiceHostInstaller.hooksStatus(data: first, host: .codex, executable: executable)
        XCTAssertTrue(status.found)
        XCTAssertTrue(status.matches)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"], "Unrelated events are preserved.")
        let stopGroups = (hooks["Stop"] as? [Any]) ?? []
        let stopHandlers: [[String: Any]] = stopGroups.compactMap { ($0 as? [String: Any])?["hooks"] as? [Any] }
            .flatMap { $0.compactMap { $0 as? [String: Any] } }
        XCTAssertTrue(stopHandlers.contains { ($0["command"] as? String) == "/usr/bin/true" },
                      "Other handlers sharing an event are preserved.")
    }

    func testClaudeHooksMergePreservesSettingsAndRemovesStaleInterrupt() throws {
        let staleInterrupt: [String: Any] = ["type": "mcp_tool", "server": "dictaflow", "tool": "on_interrupt",
                                             "input": ["session_id": "${session_id}"]]
        let existing: [String: Any] = [
            "model": "keep-model",
            "hooks": ["Interrupt": [["hooks": [staleInterrupt]]]],
        ]
        let merged = try AgentVoiceHostInstaller.mergedClaudeSettings(
            existing: JSONSerialization.data(withJSONObject: existing), executable: executable)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "keep-model")
        let status = AgentVoiceHostInstaller.hooksStatus(data: merged, host: .claudeCode, executable: executable)
        XCTAssertTrue(status.matches, "Stale invented Interrupt hooks must not survive a merge.")
    }

    func testClaudeMergeAddsGuardPreservesOthersAndIsIdempotent() throws {
        let other: [String: Any] = ["type": "command", "command": "echo lint"]
        // Previous revision installed the guard in exec form, which needs
        // Claude Code 2.1.139+. It must be replaced with shell form.
        let staleGuard: [String: Any] = ["type": "command", "command": "/old/dictaflow-mcp",
                                         "args": ["--hook-event", "PreToolUse", "--host", "claude"]]
        let staleLifecycle: [String: Any] = ["type": "mcp_tool", "server": "dictaflow", "tool": "on_stop",
                                             "input": ["session_id": "${session_id}"]]
        let existing: [String: Any] = [
            "model": "keep-model",
            "hooks": [
                "Stop": [["hooks": [other, staleLifecycle]]],
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [other]],
                    ["matcher": "mcp__dictaflow__.*", "hooks": [staleGuard]],
                ],
            ],
        ]
        let first = try AgentVoiceHostInstaller.mergedClaudeSettings(
            existing: JSONSerialization.data(withJSONObject: existing), executable: executable)
        let second = try AgentVoiceHostInstaller.mergedClaudeSettings(existing: first, executable: executable)
        XCTAssertEqual(first, second, "Merging twice must not duplicate or reorder our hooks.")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "keep-model")
        let status = AgentVoiceHostInstaller.hooksStatus(data: first, host: .claudeCode, executable: executable)
        XCTAssertTrue(status.found)
        XCTAssertTrue(status.matches)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let stopHandlers = ((hooks["Stop"] as? [[String: Any]]) ?? []).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        XCTAssertTrue(stopHandlers.contains { ($0["command"] as? String) == "echo lint" },
                      "Other handlers sharing an event are preserved.")
        let guardGroups = ((hooks["PreToolUse"] as? [[String: Any]]) ?? [])
            .filter { ($0["matcher"] as? String) == "mcp__dictaflow__.*" }
        XCTAssertEqual(guardGroups.count, 1)
        let guardHandlers = (guardGroups.first?["hooks"] as? [[String: Any]]) ?? []
        XCTAssertEqual(guardHandlers.count, 1)
        XCTAssertEqual(guardHandlers.first?["command"] as? String,
                       "'\(executable)' --hook-event PreToolUse --host claude",
                       "The stale exec-form guard is replaced with shell form.")
        XCTAssertNil(guardHandlers.first?["args"], "The current guard carries no exec-form args.")
        let stopInputs = stopHandlers.compactMap { $0["input"] as? [String: String] }
        XCTAssertTrue(stopInputs.contains { $0["agent_id"] == "${agent_id}" },
                      "Stale lifecycle handlers gain the agent_id substitution.")
        let bashGroups = ((hooks["PreToolUse"] as? [[String: Any]]) ?? [])
            .filter { ($0["matcher"] as? String) == "Bash" }
        XCTAssertEqual(bashGroups.count, 1, "Unrelated matcher groups are preserved.")
    }

    func testClaudeStatusDetectsStaleLifecycleGuardPathAndMatcher() throws {
        // Lifecycle without agent_id, a stale guard path, an exec-form
        // guard with the current path, and our guard under the wrong
        // matcher are all found but not current.
        let staleLifecycle: [String: Any] = ["type": "mcp_tool", "server": "dictaflow",
                                             "tool": "on_user_prompt_submit",
                                             "input": ["session_id": "${session_id}",
                                                       "prompt": "${prompt}"]]
        let stalePath: [String: Any] = ["type": "command",
                                        "command": "'/old/dictaflow-mcp' --hook-event PreToolUse --host claude"]
        let staleExecForm: [String: Any] = ["type": "command", "command": executable,
                                            "args": ["--hook-event", "PreToolUse", "--host", "claude"]]
        let wrongMatcher = try XCTUnwrap(AgentVoiceHostInstaller.expectedCommandHookHandler(
            for: .claudeCode, event: "PreToolUse", executable: executable))
        for hooksValue: [String: Any] in [
            ["UserPromptSubmit": [["hooks": [staleLifecycle]]]],
            ["PreToolUse": [["matcher": "mcp__dictaflow__.*", "hooks": [stalePath]]]],
            ["PreToolUse": [["matcher": "mcp__dictaflow__.*", "hooks": [staleExecForm]]]],
            ["PreToolUse": [["matcher": "Bash", "hooks": [wrongMatcher]]]],
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["hooks": hooksValue])
            let status = AgentVoiceHostInstaller.hooksStatus(data: data, host: .claudeCode, executable: executable)
            XCTAssertTrue(status.found)
            XCTAssertFalse(status.matches)
        }
    }

    func testMuseMergeAddsGuardPreservesServersAndOthers() throws {
        let other: [String: Any] = ["type": "command", "command": "echo note"]
        let staleGuard: [String: Any] = ["type": "command",
                                         "command": "'/old/dictaflow-mcp' --hook-event PreToolUse --host muse"]
        let existing: [String: Any] = [
            "schema_version": 1,
            "provider": "meta",
            "mcp_servers": ["other": ["transport": "stdio", "command": "/bin/other"]],
            "hooks": [
                "UserPromptSubmit": [["hooks": [other]]],
                "PreToolUse": [["matcher": "mcp__dictaflow__.*", "hooks": [staleGuard]]],
            ],
        ]
        let first = try AgentVoiceHostInstaller.mergedMuseSettings(
            existing: JSONSerialization.data(withJSONObject: existing),
            executable: executable, arguments: arguments(host: .museCode))
        let second = try AgentVoiceHostInstaller.mergedMuseSettings(
            existing: first, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertEqual(first, second, "Merging twice must not duplicate or reorder our hooks.")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(root["provider"] as? String, "meta")
        let (found, matches, _) = AgentVoiceHostInstaller.museEntryStatus(
            data: first, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertTrue(found)
        XCTAssertTrue(matches)
        let status = AgentVoiceHostInstaller.hooksStatus(data: first, host: .museCode, executable: executable)
        XCTAssertTrue(status.found)
        XCTAssertTrue(status.matches)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let promptHandlers = ((hooks["UserPromptSubmit"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        XCTAssertTrue(promptHandlers.contains { ($0["command"] as? String) == "echo note" },
                      "Unrelated hooks are preserved.")
        XCTAssertNil(hooks["Stop"], "Muse receives the guard only; no lifecycle hooks are invented.")
    }

    func testMuseMergeRejectsInvalidHooksShape() throws {
        let existing: [String: Any] = ["schema_version": 1, "hooks": ["PreToolUse": "not-groups"]]
        XCTAssertThrowsError(try AgentVoiceHostInstaller.mergedMuseSettings(
            existing: JSONSerialization.data(withJSONObject: existing),
            executable: executable, arguments: arguments(host: .museCode))) { error in
            guard case AgentVoiceHostInstaller.InstallerError.invalidHooksFile = error else {
                return XCTFail("Expected invalidHooksFile, got \(error)")
            }
        }
    }

    func testHooksStatusReportsMissingAndStale() throws {
        XCTAssertFalse(AgentVoiceHostInstaller.hooksStatus(data: nil, host: .codex, executable: executable).found)
        let staleHandler: [String: Any] = ["type": "mcp_tool", "server": "dictaflow",
                                           "tool": "on_stop", "input": ["session_id": "old"]]
        let stale: [String: Any] = ["hooks": ["Stop": [["hooks": [staleHandler]]]]]
        let data = try JSONSerialization.data(withJSONObject: stale)
        let status = AgentVoiceHostInstaller.hooksStatus(data: data, host: .codex, executable: executable)
        XCTAssertTrue(status.found)
        XCTAssertFalse(status.matches)
    }

    func testHooksMergeRejectsInvalidJSONWithoutInventingAFile() async throws {
        let home = try makeHome()
        let url = AgentVoiceHostInstaller.codexHooksURL(homeDirectoryURL: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        do {
            _ = try await AgentVoiceHostInstaller.setUp(
                host: .codex, executable: try makeExecutable(), appID: "com.dictaflow.dev",
                installationID: installation, agentVoiceEnabled: true,
                runner: StubRunner(handlers: []), homeDirectoryURL: home, cliDiscovery: { _ in "/bin/codex" })
            XCTFail("Expected invalidHooksFile")
        } catch let error as AgentVoiceHostInstaller.InstallerError {
            XCTAssertEqual(error, .invalidHooksFile(path: url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8), "An invalid file is never overwritten.")
    }

    // MARK: - Codex tool pre-approval

    func testCodexApprovalMergeInsertsKeyAndPreservesRest() throws {
        let existing = [
            "model = \"keep-me\"",
            "",
            "[mcp_servers.other]",
            "command = \"/usr/bin/other\"",
            "",
            "[mcp_servers.dictaflow]",
            "command = \"/Applications/DictaFlow Dev.app/Contents/MacOS/dictaflow-mcp\"",
            "args = [\"--app-id\", \"com.dictaflow.dev\"]",
            "",
            "[mcp_servers.dictaflow.tools.prepare_spoken_response]",
            "approval_mode = \"approve\"",
            "",
        ].joined(separator: "\n")
        let result = try AgentVoiceHostInstaller.mergedCodexApproval(existing: existing)
        guard case .applied(let updated) = result else {
            return XCTFail("Expected applied, got \(result)")
        }
        let expected = [
            "model = \"keep-me\"",
            "",
            "[mcp_servers.other]",
            "command = \"/usr/bin/other\"",
            "",
            "[mcp_servers.dictaflow]",
            "default_tools_approval_mode = \"approve\"",
            "command = \"/Applications/DictaFlow Dev.app/Contents/MacOS/dictaflow-mcp\"",
            "args = [\"--app-id\", \"com.dictaflow.dev\"]",
            "",
            "[mcp_servers.dictaflow.tools.prepare_spoken_response]",
            "approval_mode = \"approve\"",
            "",
        ].joined(separator: "\n")
        XCTAssertEqual(updated, expected)
        XCTAssertEqual(try AgentVoiceHostInstaller.mergedCodexApproval(existing: updated), .alreadyApproved,
                       "Merging the result must be a no-op.")
    }

    func testCodexApprovalLeavesExistingValueAlone() throws {
        let existing = [
            "[mcp_servers.dictaflow]",
            "default_tools_approval_mode = \"prompt\"",
            "command = \"/bin/dictaflow-mcp\"",
        ].joined(separator: "\n")
        XCTAssertEqual(try AgentVoiceHostInstaller.mergedCodexApproval(existing: existing), .alreadyApproved,
                       "A user-set value is never overwritten, even when it is not ours.")
    }

    func testCodexApprovalIgnoresCommentedKey() throws {
        let existing = [
            "[mcp_servers.dictaflow]",
            "# default_tools_approval_mode = \"prompt\"",
            "command = \"/bin/dictaflow-mcp\"",
        ].joined(separator: "\n")
        let result = try AgentVoiceHostInstaller.mergedCodexApproval(existing: existing)
        guard case .applied(let updated) = result else {
            return XCTFail("A commented key is inactive, so the real key must be added; got \(result)")
        }
        XCTAssertTrue(updated.contains("\ndefault_tools_approval_mode = \"approve\"\n"))
    }

    func testCodexApprovalSkipsWhenNoServerEntry() throws {
        XCTAssertEqual(try AgentVoiceHostInstaller.mergedCodexApproval(existing: ""), .noServerEntry)
        let otherOnly = [
            "[mcp_servers.other]",
            "command = \"/usr/bin/other\"",
        ].joined(separator: "\n")
        XCTAssertEqual(try AgentVoiceHostInstaller.mergedCodexApproval(existing: otherOnly), .noServerEntry)
    }

    func testCodexApprovalCountsOnlyItsOwnSection() throws {
        // An approval key under another server must not satisfy ours.
        let existing = [
            "[mcp_servers.other]",
            "default_tools_approval_mode = \"approve\"",
            "",
            "[mcp_servers.dictaflow]",
            "command = \"/bin/dictaflow-mcp\"",
        ].joined(separator: "\n")
        let result = try AgentVoiceHostInstaller.mergedCodexApproval(existing: existing)
        guard case .applied(let updated) = result else {
            return XCTFail("Expected applied, got \(result)")
        }
        let expected = [
            "[mcp_servers.other]",
            "default_tools_approval_mode = \"approve\"",
            "",
            "[mcp_servers.dictaflow]",
            "default_tools_approval_mode = \"approve\"",
            "command = \"/bin/dictaflow-mcp\"",
        ].joined(separator: "\n")
        XCTAssertEqual(updated, expected)
    }

    func testCodexApprovalTreatsDottedRootKeyAsApproved() throws {
        let existing = "mcp_servers.dictaflow.default_tools_approval_mode = \"approve\"\n"
        XCTAssertEqual(try AgentVoiceHostInstaller.mergedCodexApproval(existing: existing), .alreadyApproved,
                       "Adding a table key next to an equivalent dotted key would corrupt the file.")
    }

    func testCodexApprovalThrowsOnDuplicateTables() {
        let existing = [
            "[mcp_servers.dictaflow]",
            "command = \"/bin/one\"",
            "[mcp_servers.dictaflow]",
            "command = \"/bin/two\"",
        ].joined(separator: "\n")
        XCTAssertThrowsError(try AgentVoiceHostInstaller.mergedCodexApproval(existing: existing)) { error in
            guard case AgentVoiceHostInstaller.InstallerError.invalidCodexConfig = error else {
                return XCTFail("Expected invalidCodexConfig, got \(error)")
            }
        }
    }

    func testCodexSetUpSkipsApprovalNoteWhenServerEntryMissing() async throws {
        // The stubbed `mcp add` writes no real config file, so setup must
        // say pre-approval was skipped instead of claiming it.
        let executable = try makeExecutable()
        let expectedArgs = arguments(host: .codex)
        let payload: [String: Any] = ["transport": ["type": "stdio", "command": executable,
                                                    "args": expectedArgs]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let runner = StubRunner(handlers: [
            { _, args in args.first == "mcp" && args.contains("add")
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: "Added", stderr: "") : nil },
            { _, args in args == ["mcp", "get", "--json", "dictaflow"]
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: json, stderr: "") : nil },
        ])
        let message = try await AgentVoiceHostInstaller.setUp(
            host: .codex, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, agentVoiceEnabled: true,
            runner: runner, homeDirectoryURL: makeHome(), cliDiscovery: { _ in "/bin/codex" })
        XCTAssertTrue(message.contains("Always allow"),
                      "Without a server entry the message must point at the manual fallback.")
    }

    func testCodexSetUpPreApprovesToolsInExistingConfig() async throws {
        let executable = try makeExecutable()
        let expectedArgs = arguments(host: .codex)
        let payload: [String: Any] = ["transport": ["type": "stdio", "command": executable,
                                                    "args": expectedArgs]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let runner = StubRunner(handlers: [
            { _, args in args.first == "mcp" && args.contains("add")
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: "Added", stderr: "") : nil },
            { _, args in args == ["mcp", "get", "--json", "dictaflow"]
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: json, stderr: "") : nil },
            { _, args in args == ["mcp", "list"]
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: "dictaflow", stderr: "") : nil },
        ])
        let home = try makeHome()
        let configURL = AgentVoiceHostInstaller.codexConfigURL(homeDirectoryURL: home)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "model = \"keep-me\"\n\n[mcp_servers.dictaflow]\ncommand = \"x\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        let message = try await AgentVoiceHostInstaller.setUp(
            host: .codex, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, agentVoiceEnabled: true,
            runner: runner, homeDirectoryURL: home, cliDiscovery: { _ in "/bin/codex" })
        XCTAssertTrue(message.contains("pre-approved"),
                      "Setup must disclose that it pre-approved DictaFlow's tools.")
        let written = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(written.contains("\ndefault_tools_approval_mode = \"approve\"\n"))
        XCTAssertTrue(written.contains("model = \"keep-me\""), "Unrelated config must survive.")
    }

    func testCodexSetUpRestoresConfigWhenValidationFails() async throws {
        let executable = try makeExecutable()
        let expectedArgs = arguments(host: .codex)
        let payload: [String: Any] = ["transport": ["type": "stdio", "command": executable,
                                                    "args": expectedArgs]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let runner = StubRunner(handlers: [
            { _, args in args.first == "mcp" && args.contains("add")
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: "Added", stderr: "") : nil },
            { _, args in args == ["mcp", "get", "--json", "dictaflow"]
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: json, stderr: "") : nil },
            { _, args in args == ["mcp", "list"]
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 1, stdout: "", stderr: "parse error") : nil },
        ])
        let home = try makeHome()
        let configURL = AgentVoiceHostInstaller.codexConfigURL(homeDirectoryURL: home)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let original = "model = \"keep-me\"\n\n[mcp_servers.dictaflow]\ncommand = \"x\"\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        do {
            _ = try await AgentVoiceHostInstaller.setUp(
                host: .codex, executable: executable, appID: "com.dictaflow.dev",
                installationID: installation, agentVoiceEnabled: true,
                runner: runner, homeDirectoryURL: home, cliDiscovery: { _ in "/bin/codex" })
            XCTFail("Expected invalidCodexConfig when the parse check fails.")
        } catch let error as AgentVoiceHostInstaller.InstallerError {
            XCTAssertEqual(error, .invalidCodexConfig(path: configURL.path))
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original,
                       "A failed validation must restore the untouched bytes.")
    }

    func testCodexRollbackPreservesChangesMadeDuringValidation() async throws {
        let helper = try makeExecutable()
        let home = try makeHome()
        let config = AgentVoiceHostInstaller.codexConfigURL(homeDirectoryURL: home)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "[mcp_servers.dictaflow]\ncommand = \"x\"\n"
        let concurrent = "model = \"edited-during-setup\"\n" + original
        try original.write(to: config, atomically: true, encoding: .utf8)
        let entry = ["transport": ["command": helper, "args": arguments(host: .codex)]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
        let runner = StubRunner(handlers: [{ _, args in
            if args.contains("add") { return .init(exitCode: 0, stdout: "", stderr: "") }
            if args.contains("get") { return .init(exitCode: 0, stdout: json, stderr: "") }
            if args.contains("list") {
                try? concurrent.write(to: config, atomically: true, encoding: .utf8)
                return .init(exitCode: 1, stdout: "", stderr: "")
            }
            return nil
        }])
        do {
            _ = try await AgentVoiceHostInstaller.setUp(
                host: .codex, executable: helper, appID: "com.dictaflow.dev",
                installationID: installation, agentVoiceEnabled: true,
                runner: runner, homeDirectoryURL: home, cliDiscovery: { _ in "/bin/codex" })
            XCTFail("Expected rollback conflict")
        } catch let error as AgentVoiceHostInstaller.InstallerError {
            XCTAssertEqual(error, .codexRollbackConflict(path: config.path))
        }
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), concurrent)
    }

    func testCodexSetUpRestoresConfigWhenGateThrows() async throws {
        struct FailingListRunner: AgentVoiceHostInstaller.CommandRunner {
            let json: String
            func run(executablePath: String, arguments: [String]) async throws -> AgentVoiceHostInstaller.CommandResult {
                if arguments == ["--version"] {
                    return .init(exitCode: 0, stdout: "codex-cli 0.156.0", stderr: "")
                }
                if arguments == ["mcp", "list"] {
                    throw AgentVoiceHostInstaller.InstallerError.commandFailed(host: "Codex", detail: "boom")
                }
                if arguments == ["mcp", "get", "--json", "dictaflow"] {
                    return AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: json, stderr: "")
                }
                if arguments.first == "mcp", arguments.contains("add") {
                    return AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: "Added", stderr: "")
                }
                throw AgentVoiceHostInstaller.InstallerError.commandFailed(host: "stub", detail: "unexpected \(arguments)")
            }
        }
        let executable = try makeExecutable()
        let expectedArgs = arguments(host: .codex)
        let payload: [String: Any] = ["transport": ["type": "stdio", "command": executable,
                                                    "args": expectedArgs]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let home = try makeHome()
        let configURL = AgentVoiceHostInstaller.codexConfigURL(homeDirectoryURL: home)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let original = "model = \"keep-me\"\n\n[mcp_servers.dictaflow]\ncommand = \"x\"\n"
        try original.write(to: configURL, atomically: true, encoding: .utf8)
        do {
            _ = try await AgentVoiceHostInstaller.setUp(
                host: .codex, executable: executable, appID: "com.dictaflow.dev",
                installationID: installation, agentVoiceEnabled: true,
                runner: FailingListRunner(json: json), homeDirectoryURL: home,
                cliDiscovery: { _ in "/bin/codex" })
            XCTFail("Expected the gate error to propagate.")
        } catch let error as AgentVoiceHostInstaller.InstallerError {
            guard case .commandFailed = error else {
                return XCTFail("Expected the gate error, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original,
                       "A gate error must also restore the untouched bytes.")
    }

    // MARK: - Status mapping

    func testStatusMapping() {
        XCTAssertEqual(
            AgentVoiceHostInstaller.HostState(cliPath: "/bin/codex", configuredEntryFound: true,
                                              entryMatchesCurrent: true).status, .configured)
        // A stale entry still needs setup, so it maps back to not configured.
        XCTAssertEqual(
            AgentVoiceHostInstaller.HostState(cliPath: "/bin/codex", configuredEntryFound: true,
                                              entryMatchesCurrent: false).status, .foundNotConfigured)
        XCTAssertEqual(
            AgentVoiceHostInstaller.HostState(cliPath: "/bin/codex", configuredEntryFound: false,
                                              entryMatchesCurrent: false).status, .foundNotConfigured)
        XCTAssertEqual(
            AgentVoiceHostInstaller.HostState(cliPath: nil, configuredEntryFound: false,
                                              entryMatchesCurrent: false).status, .notFound)
    }
}
