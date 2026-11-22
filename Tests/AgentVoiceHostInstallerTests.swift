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

    func testMuseEntryStatusReportsMissingAndStale() {
        let (missingFound, missingMatches, _) = AgentVoiceHostInstaller.museEntryStatus(
            data: nil, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertFalse(missingFound)
        XCTAssertFalse(missingMatches)

        let stale = try? JSONSerialization.data(withJSONObject: ["mcp_servers": ["omdo": ["command": "/old"]]])
        let (staleFound, staleMatches, _) = AgentVoiceHostInstaller.museEntryStatus(
            data: stale, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertTrue(staleFound)
        XCTAssertFalse(staleMatches)
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

    func testMuseSelectsUserConfigOverride() {
        let home = URL(fileURLWithPath: "/fixture-home")
        XCTAssertEqual(AgentVoiceHostInstaller.museSettingsURL(homeDirectoryURL: home).path,
                       "/fixture-home/.config/muse/settings.json")
        XCTAssertEqual(AgentVoiceHostInstaller.museSettingsURL(homeDirectoryURL: home, configHome: "/fixture-config").path,
                       "/fixture-config/muse/settings.json")
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

    func testRefreshStateReportsUnsupportedCodexVersionWithoutCheckingEntry() async throws {
        let executable = try makeExecutable()
        let home = try makeHome()
        let calls = CallLog()
        let runner = StubRunner(handlers: [{ _, args in
            calls.record(args)
            if args == ["--version"] {
                return .init(exitCode: 0, stdout: "codex-cli 0.155.0", stderr: "")
            }
            return .init(exitCode: 0, stdout: "configured", stderr: "")
        }])
        let state = await AgentVoiceHostInstaller.refreshState(
            host: .codex, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, runner: runner, homeDirectoryURL: home,
            cliDiscovery: { _ in "/bin/codex" })
        XCTAssertEqual(state.status, .unsupportedVersion,
                       "Codex below 0.156.0 rejects every voice call, so refresh must not report it ready.")
        XCTAssertEqual(calls.all, [["--version"]],
                       "The version probe must decide before any entry check runs.")
    }

    func testRefreshStateReportsNotReadyWhenCodexVersionProbeFails() async throws {
        let executable = try makeExecutable()
        let home = try makeHome()
        let calls = CallLog()
        struct FailingVersionRunner: AgentVoiceHostInstaller.CommandRunner {
            let calls: CallLog
            func run(executablePath: String, arguments: [String]) async throws -> AgentVoiceHostInstaller.CommandResult {
                calls.record(arguments)
                throw AgentVoiceHostInstaller.InstallerError.commandFailed(host: "stub", detail: "version boom")
            }
        }
        let state = await AgentVoiceHostInstaller.refreshState(
            host: .codex, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, runner: FailingVersionRunner(calls: calls),
            homeDirectoryURL: home, cliDiscovery: { _ in "/bin/codex" })
        XCTAssertEqual(state.status, .foundNotConfigured,
                       "A failed version probe is unverified, never ready, even with a matching entry.")
        XCTAssertEqual(calls.all, [["--version"]],
                       "The failed probe must decide before any entry check runs.")
    }

    func testMergePreservesUnrelatedCommandMentioningGuardStrings() throws {
        let unrelated: [String: Any] = ["type": "command",
                                        "command": "logger 'dictaflow-mcp --hook-event guard ran'"]
        let existing: [String: Any] = [
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [unrelated]]]],
        ]
        let merged = try AgentVoiceHostInstaller.mergedClaudeSettings(
            existing: JSONSerialization.data(withJSONObject: existing), executable: executable)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let bashGroups = ((hooks["PreToolUse"] as? [[String: Any]]) ?? [])
            .filter { ($0["matcher"] as? String) == "Bash" }
        let bashHandlers = (bashGroups.first?["hooks"] as? [[String: Any]]) ?? []
        XCTAssertEqual(bashHandlers.count, 1,
                       "A command that only mentions the helper and marker is not DictaFlow-owned.")
        XCTAssertEqual(bashHandlers.first?["command"] as? String, unrelated["command"] as? String)
        // The unrelated command alone must not count as a DictaFlow hook.
        let alone = try JSONSerialization.data(withJSONObject: ["hooks":
            ["PreToolUse": [["matcher": "Bash", "hooks": [unrelated]]]]])
        XCTAssertFalse(AgentVoiceHostInstaller.hooksStatus(data: alone, host: .claudeCode,
                                                           executable: executable).found)
    }

    func testRefreshStateReportsConfiguredCodexAtVersionFloor() async throws {
        let executable = try makeExecutable()
        let expectedArgs = arguments(host: .codex)
        let payload: [String: Any] = ["transport": ["type": "stdio", "command": executable, "args": expectedArgs]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let runner = StubRunner(handlers: [
            { _, args in args == ["mcp", "get", "--json", "omdo"]
                ? AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: json, stderr: "") : nil },
        ])
        let home = try makeHome()
        let state = await AgentVoiceHostInstaller.refreshState(
            host: .codex, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, runner: runner, homeDirectoryURL: home,
            cliDiscovery: { _ in "/bin/codex" })
        XCTAssertEqual(state.status, .configured)
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

    func testMuseSetUpWritesRealFileInTemporaryHome() async throws {
        let executable = try makeExecutable()
        let home = try makeHome()
        let message = try await AgentVoiceHostInstaller.setUp(
            host: .museCode, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, agentVoiceEnabled: true,
            runner: StubRunner(handlers: []), homeDirectoryURL: home, hostIdle: { true })
        XCTAssertTrue(message.contains("Start a new session"))
        XCTAssertTrue(message.contains("configured"))
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
                       "mcp__omdo__.*")
        XCTAssertEqual(AgentVoiceHostInstaller.expectedHookMatcher(for: .museCode, event: "PreToolUse"),
                       "mcp__omdo__.*")
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
                           "Omdo: Agent Voice",
                           "\(event) must show the DictaFlow label in host review, not \"Unnamed hook\".")
        }
        for host: AgentVoiceHostInstaller.Host in [.claudeCode, .museCode] {
            XCTAssertEqual(AgentVoiceHostInstaller.expectedCommandHookHandler(
                for: host, event: "PreToolUse", executable: executable)?["statusMessage"] as? String,
                           "Omdo: Agent Voice")
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
                    ["matcher": "mcp__omdo__.*", "hooks": [staleGuard]],
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
            .filter { ($0["matcher"] as? String) == "mcp__omdo__.*" }
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
            ["PreToolUse": [["matcher": "mcp__omdo__.*", "hooks": [stalePath]]]],
            ["PreToolUse": [["matcher": "mcp__omdo__.*", "hooks": [staleExecForm]]]],
            ["PreToolUse": [["matcher": "Bash", "hooks": [wrongMatcher]]]],
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["hooks": hooksValue])
            let status = AgentVoiceHostInstaller.hooksStatus(data: data, host: .claudeCode, executable: executable)
            XCTAssertTrue(status.found)
            XCTAssertFalse(status.matches)
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

    // MARK: - Codex tool pre-approval

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
        // An unsupported host version dominates even a matching entry: the
        // helper would reject every call from that host.
        XCTAssertEqual(
            AgentVoiceHostInstaller.HostState(cliPath: "/bin/codex", configuredEntryFound: true,
                                              entryMatchesCurrent: true,
                                              versionUnsupported: true).status, .unsupportedVersion)
    }
}
