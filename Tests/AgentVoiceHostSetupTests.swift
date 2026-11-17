import Foundation
import XCTest
@testable import DictaFlow_Dev

final class AgentVoiceHostSetupTests: XCTestCase {
    func testMuseSetupPreservesExecutableAndSeparateArguments() throws {
        let path = "/Applications/DictaFlow \"Dev\".app/Contents/MacOS/dictaflow-mcp"
        let installation = UUID()
        let snippet = try AgentVoiceHostSetup.snippet(for: .museCode, executable: path,
                                                     appID: "com.dictaflow.dev", installationID: installation)
        let configuration = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(configuration["mcp_servers"] as? [String: [String: Any]])
        let server = try XCTUnwrap(servers["dictaflow"])
        XCTAssertEqual(server["command"] as? String, path)
        XCTAssertEqual(server["args"] as? [String], ["--app-id", "com.dictaflow.dev", "--installation-id", installation.uuidString, "--host", "muse"])
        XCTAssertEqual(server["mode"] as? String, "optional")
    }

    func testHooksSnippetMatchesDocumentedHostFields() throws {
        let executable = "/Applications/DictaFlow Dev.app/Contents/MacOS/dictaflow-mcp"
        let codex = try XCTUnwrap(AgentVoiceHostSetup.hooksSnippet(for: .codex, executable: executable))
        let codexJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(codex.utf8)) as? [String: Any])
        let codexHooks = try XCTUnwrap(codexJSON["hooks"] as? [String: Any])
        XCTAssertNotNil(codexHooks["Interrupt"], "Codex documents an Interrupt event.")
        XCTAssertTrue(codex.contains("${turn_id}"))
        XCTAssertTrue(codex.contains("${prompt}"))
        XCTAssertFalse(codex.contains("agent_id"), "Codex hooks stay unchanged.")
        XCTAssertFalse(codex.contains("PreToolUse"), "Codex setup stays unchanged.")
        let claude = try XCTUnwrap(AgentVoiceHostSetup.hooksSnippet(for: .claudeCode, executable: executable))
        XCTAssertFalse(claude.contains("turn_id"), "Claude Code documents no turn_id; the snippet must not invent one.")
        XCTAssertFalse(claude.contains("Interrupt"), "Claude Code documents no Interrupt event.")
        XCTAssertTrue(claude.contains("${agent_id}"))
        XCTAssertTrue(claude.contains("PreToolUse"))
        let claudeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(claude.utf8)) as? [String: Any])
        let claudeHooks = try XCTUnwrap(claudeJSON["hooks"] as? [String: Any])
        let claudeGuards = ((claudeHooks["PreToolUse"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        XCTAssertEqual(claudeGuards.count, 1)
        XCTAssertEqual(claudeGuards.first?["command"] as? String,
                       "'\(executable)' --hook-event PreToolUse --host claude")
        XCTAssertNil(claudeGuards.first?["args"], "Exec-form args need 2.1.139+; the manual snippet supports 2.1.118+ with shell form.")
        let muse = try XCTUnwrap(AgentVoiceHostSetup.hooksSnippet(for: .museCode, executable: executable),
                                 "Muse documents command hooks; manual setup carries the guard.")
        XCTAssertTrue(muse.contains("PreToolUse"))
        XCTAssertTrue(muse.contains("--hook-event"))
        XCTAssertFalse(muse.contains("mcp_tool"), "Muse documents command hooks only.")
        XCTAssertNil(try AgentVoiceHostSetup.hooksSnippet(for: .other, executable: executable))
    }

    func testHooksSnippetMatchesOneClickSetup() throws {
        // Manual setup must install byte-identical hook definitions.
        let executable = "/Applications/DictaFlow Dev.app/Contents/MacOS/dictaflow-mcp"
        for host: AgentVoiceHostAvailability.Host in [.codex, .claudeCode, .museCode] {
            let snippet = try XCTUnwrap(AgentVoiceHostSetup.hooksSnippet(for: host, executable: executable))
            let snippetHooks = try XCTUnwrap(
                (JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])?["hooks"] as? [String: Any])
            let merged: Data
            switch host {
            case .codex:
                merged = try AgentVoiceHostInstaller.mergedCodexHooks(existing: nil)
            case .claudeCode:
                merged = try AgentVoiceHostInstaller.mergedClaudeSettings(existing: nil, executable: executable)
            case .museCode:
                let root = try AgentVoiceHostInstaller.mergedMuseHooks(root: [:], executable: executable,
                                                                       path: "snippet-check")
                merged = try JSONSerialization.data(withJSONObject: root)
            case .other:
                continue
            }
            let mergedHooks = try XCTUnwrap(
                (JSONSerialization.jsonObject(with: merged) as? [String: Any])?["hooks"] as? [String: Any])
            XCTAssertEqual(canonical(snippetHooks), canonical(mergedHooks),
                           "Manual and one-click \(host.name) hooks must match exactly.")
        }
    }

    func testClaudeGuardCommandDoesNotInterpretExecutableCharacters() throws {
        // Shell form must survive hostile paths on every supported Claude
        // release. A local shell fixture captures argv without invoking a
        // host or MCP helper.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stub = directory.appendingPathComponent("dictaflow-mcp")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let command = AgentVoiceHostInstaller.claudeGuardCommand(executable: stub.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "--hook-event\nPreToolUse\n--host\nclaude\n")
        let path = "/Applications/DictaFlow's $example `name`.app/Contents/MacOS/dictaflow-mcp"
        let quoted = AgentVoiceHostInstaller.claudeGuardCommand(executable: path)
        XCTAssertTrue(quoted.hasSuffix(" --hook-event PreToolUse --host claude"))
        let echo = Process()
        echo.executableURL = URL(fileURLWithPath: "/bin/sh")
        echo.arguments = ["-c", "printf '%s' " + quoted.prefix(quoted.count - " --hook-event PreToolUse --host claude".count)]
        let echoed = Pipe()
        echo.standardOutput = echoed
        try echo.run()
        XCTAssertEqual(String(decoding: echoed.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), path)
        echo.waitUntilExit()
        XCTAssertEqual(echo.terminationStatus, 0)
    }

    func testMuseGuardCommandDoesNotInterpretExecutableCharacters() throws {
        let path = "/Applications/DictaFlow's $example `name`.app/Contents/MacOS/dictaflow-mcp"
        // A local shell fixture captures argv without invoking a host or MCP helper.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stub = directory.appendingPathComponent("dictaflow-mcp")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let command = AgentVoiceHostInstaller.museGuardCommand(executable: stub.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "--hook-event\nPreToolUse\n--host\nmuse\n")
        // The hostile path itself must round-trip through a real shell byte-identical.
        let quoted = AgentVoiceHostInstaller.museGuardCommand(executable: path)
        XCTAssertTrue(quoted.hasSuffix(" --hook-event PreToolUse --host muse"))
        let echo = Process()
        echo.executableURL = URL(fileURLWithPath: "/bin/sh")
        echo.arguments = ["-c", "printf '%s' " + quoted.prefix(quoted.count - " --hook-event PreToolUse --host muse".count)]
        let echoed = Pipe()
        echo.standardOutput = echoed
        try echo.run()
        XCTAssertEqual(String(decoding: echoed.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), path)
        echo.waitUntilExit()
        XCTAssertEqual(echo.terminationStatus, 0)
    }

    private func canonical(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func testCodexSnippetPreApprovesTools() throws {
        let snippet = try AgentVoiceHostSetup.snippet(for: .codex, executable: "/bin/dictaflow-mcp",
                                                      appID: "com.dictaflow.dev", installationID: UUID())
        XCTAssertTrue(snippet.contains("[mcp_servers.dictaflow]"))
        XCTAssertTrue(snippet.contains("default_tools_approval_mode = \"approve\""),
                      "Manual setup must carry the same pre-approval one-click setup writes.")
    }

    func testShellSetupDoesNotInterpretExecutableCharacters() throws {
        let path = "/Applications/DictaFlow's $example `name`.app/Contents/MacOS/dictaflow-mcp"
        let snippet = try AgentVoiceHostSetup.snippet(for: .claudeCode, executable: path,
                                                     appID: "com.dictaflow.dev", installationID: UUID())
        // A local shell fixture captures argv without invoking a host or MCP helper.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "claude() { printf '%s\\n' \"$6\" \"$7\" \"$8\" \"$9\"; }; " + snippet]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "--scope\nuser\n--\n\(path)\n")
    }
}
