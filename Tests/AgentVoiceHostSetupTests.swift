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
        let codex = try XCTUnwrap(AgentVoiceHostSetup.hooksSnippet(for: .codex))
        let codexJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(codex.utf8)) as? [String: Any])
        let codexHooks = try XCTUnwrap(codexJSON["hooks"] as? [String: Any])
        XCTAssertNotNil(codexHooks["Interrupt"], "Codex documents an Interrupt event.")
        XCTAssertTrue(codex.contains("${turn_id}"))
        XCTAssertTrue(codex.contains("${prompt}"))
        let claude = try XCTUnwrap(AgentVoiceHostSetup.hooksSnippet(for: .claudeCode))
        XCTAssertFalse(claude.contains("turn_id"), "Claude Code documents no turn_id; the snippet must not invent one.")
        XCTAssertFalse(claude.contains("Interrupt"), "Claude Code documents no Interrupt event.")
        XCTAssertNil(try AgentVoiceHostSetup.hooksSnippet(for: .museCode),
                     "Muse Code documents no lifecycle hooks; manual setup stays MCP-only.")
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
