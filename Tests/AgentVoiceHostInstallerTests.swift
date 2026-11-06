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
        let (found, matches) = AgentVoiceHostInstaller.museEntryStatus(
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
        let (found, matches) = AgentVoiceHostInstaller.museEntryStatus(
            data: merged, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertTrue(found)
        XCTAssertTrue(matches)
    }

    func testMuseMergeRejectsInvalidJSON() {
        XCTAssertThrowsError(try AgentVoiceHostInstaller.mergedMuseSettings(
            existing: Data("not json".utf8), executable: executable, arguments: arguments(host: .museCode)))
    }

    func testMuseEntryStatusReportsMissingAndStale() {
        let (missingFound, missingMatches) = AgentVoiceHostInstaller.museEntryStatus(
            data: nil, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertFalse(missingFound)
        XCTAssertFalse(missingMatches)

        let stale = try? JSONSerialization.data(withJSONObject: ["mcp_servers": ["dictaflow": ["command": "/old"]]])
        let (staleFound, staleMatches) = AgentVoiceHostInstaller.museEntryStatus(
            data: stale, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertTrue(staleFound)
        XCTAssertFalse(staleMatches)
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

    func testClaudeOutputMatchesExecutableAndInstallation() {
        let output = "Command: \(executable)\nArgs: --installation-id \(installation.uuidString) --host claude"
        XCTAssertTrue(AgentVoiceHostInstaller.claudeOutputMatches(
            output: output, executable: executable, installationID: installation))
        XCTAssertFalse(AgentVoiceHostInstaller.claudeOutputMatches(
            output: "Command: /other\nArgs: --installation-id \(installation.uuidString)",
            executable: executable, installationID: installation))
    }

    // MARK: - End-to-end setup with a stubbed host CLI

    private struct StubRunner: AgentVoiceHostInstaller.CommandRunner {
        var handlers: [@Sendable (String, [String]) -> AgentVoiceHostInstaller.CommandResult?]
        func run(executablePath: String, arguments: [String]) async throws -> AgentVoiceHostInstaller.CommandResult {
            for handler in handlers {
                if let result = handler(executablePath, arguments) { return result }
            }
            throw AgentVoiceHostInstaller.InstallerError.commandFailed(host: "stub", detail: "unexpected call \(arguments)")
        }
    }

    private func makeExecutable() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        XCTAssertTrue(AgentVoiceHostInstaller.hooksStatus(data: hooksData, host: .codex).matches)
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
        let output = "Command: \(executable)\nArgs: \(installation.uuidString)"
        struct RecordingRunner: AgentVoiceHostInstaller.CommandRunner {
            let log: CallLog
            let output: String
            func run(executablePath: String, arguments: [String]) async throws -> AgentVoiceHostInstaller.CommandResult {
                log.record(arguments)
                return AgentVoiceHostInstaller.CommandResult(exitCode: 0, stdout: output, stderr: "")
            }
        }
        let runner = RecordingRunner(log: log, output: output)
        let home = try makeHome()
        let message = try await AgentVoiceHostInstaller.setUp(
            host: .claudeCode, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, agentVoiceEnabled: false,
            runner: runner, homeDirectoryURL: home, cliDiscovery: { _ in "/bin/claude" })
        let claudeHooks = try Data(contentsOf: AgentVoiceHostInstaller.claudeSettingsURL(homeDirectoryURL: home))
        XCTAssertTrue(AgentVoiceHostInstaller.hooksStatus(data: claudeHooks, host: .claudeCode).matches)
        XCTAssertTrue(message.contains("Turn Enable Agent Voice on"))
        XCTAssertEqual(log.all.count, 3)
        XCTAssertEqual(log.all.first, ["mcp", "remove", "dictaflow", "-s", "user"])
        XCTAssertTrue(log.all[1].contains("-s"))
        XCTAssertTrue(log.all[1].contains("add"))
        XCTAssertEqual(log.all.last, ["mcp", "get", "dictaflow"])
    }

    func testMuseSetUpWritesRealFileInTemporaryHome() async throws {
        let executable = try makeExecutable()
        let home = try makeHome()
        let message = try await AgentVoiceHostInstaller.setUp(
            host: .museCode, executable: executable, appID: "com.dictaflow.dev",
            installationID: installation, agentVoiceEnabled: true,
            runner: StubRunner(handlers: []), homeDirectoryURL: home)
        XCTAssertTrue(message.contains("Start a new Muse Code session"))
        let data = try Data(contentsOf: AgentVoiceHostInstaller.museSettingsURL(homeDirectoryURL: home))
        let (found, matches) = AgentVoiceHostInstaller.museEntryStatus(
            data: data, executable: executable, arguments: arguments(host: .museCode))
        XCTAssertTrue(found)
        XCTAssertTrue(matches)
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
                       ["UserPromptSubmit", "Stop"])
        XCTAssertTrue(AgentVoiceHostInstaller.expectedHookEvents(for: .museCode).isEmpty)
        let codexPrompt = AgentVoiceHostInstaller.expectedHookHandler(for: .codex, event: "UserPromptSubmit")?["input"] as? [String: String]
        XCTAssertEqual(codexPrompt?["turn_id"], "${turn_id}")
        XCTAssertEqual(codexPrompt?["prompt"], "${prompt}")
        let claudePrompt = AgentVoiceHostInstaller.expectedHookHandler(for: .claudeCode, event: "UserPromptSubmit")?["input"] as? [String: String]
        XCTAssertEqual(claudePrompt?["prompt"], "${prompt}")
        XCTAssertNil(claudePrompt?["turn_id"], "Claude Code documents no turn_id; none is invented.")
        XCTAssertNil(AgentVoiceHostInstaller.expectedHookHandler(for: .claudeCode, event: "Interrupt"),
                     "Claude Code documents no Interrupt hook event.")
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
        let status = AgentVoiceHostInstaller.hooksStatus(data: first, host: .codex)
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
        let merged = try AgentVoiceHostInstaller.mergedClaudeSettings(existing: JSONSerialization.data(withJSONObject: existing))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "keep-model")
        let status = AgentVoiceHostInstaller.hooksStatus(data: merged, host: .claudeCode)
        XCTAssertTrue(status.matches, "Stale invented Interrupt hooks must not survive a merge.")
    }

    func testHooksStatusReportsMissingAndStale() throws {
        XCTAssertFalse(AgentVoiceHostInstaller.hooksStatus(data: nil, host: .codex).found)
        let staleHandler: [String: Any] = ["type": "mcp_tool", "server": "dictaflow",
                                           "tool": "on_stop", "input": ["session_id": "old"]]
        let stale: [String: Any] = ["hooks": ["Stop": [["hooks": [staleHandler]]]]]
        let data = try JSONSerialization.data(withJSONObject: stale)
        let status = AgentVoiceHostInstaller.hooksStatus(data: data, host: .codex)
        XCTAssertTrue(status.found)
        XCTAssertFalse(status.matches)
    }

    func testHooksMergeRejectsInvalidJSONWithoutInventingAFile() async throws {
        let home = try makeHome()
        let url = AgentVoiceHostInstaller.codexHooksURL(homeDirectoryURL: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try AgentVoiceHostInstaller.mergedCodexHooks(existing: Data("not json".utf8))) { error in
            guard case AgentVoiceHostInstaller.InstallerError.invalidHooksFile = error else {
                return XCTFail("Expected invalidHooksFile, got \(error)")
            }
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

    func testCodexSetUpRestoresConfigWhenGateThrows() async throws {
        struct FailingListRunner: AgentVoiceHostInstaller.CommandRunner {
            let json: String
            func run(executablePath: String, arguments: [String]) async throws -> AgentVoiceHostInstaller.CommandResult {
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
