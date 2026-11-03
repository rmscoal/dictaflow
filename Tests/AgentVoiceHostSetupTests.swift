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

    func testShellSetupDoesNotInterpretExecutableCharacters() throws {
        let path = "/Applications/DictaFlow's $example `name`.app/Contents/MacOS/dictaflow-mcp"
        let snippet = try AgentVoiceHostSetup.snippet(for: .claudeCode, executable: path,
                                                     appID: "com.dictaflow.dev", installationID: UUID())
        // A local shell fixture captures argv without invoking a host or MCP helper.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "claude() { printf '%s' \"$7\"; }; " + snippet]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), path)
    }
}
