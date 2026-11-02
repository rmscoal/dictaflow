import AgentVoiceMCP
import Darwin
import Foundation
import Testing

struct MCPCompatibilityTests {
    private var codexInitialization: Data {
        Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.166.0"}}}"#.utf8)
    }

    @Test func compatibilityOnlyIgnoresUnsupportedInitializationExtensions() throws {
        let transformed = InitializationCompatibilityTransport.compatibleInitialization(codexInitialization)
        let message = try #require(JSONSerialization.jsonObject(with: transformed) as? [String: Any])
        let params = try #require(message["params"] as? [String: Any])
        #expect(params["protocolVersion"] as? String == "2025-06-18")
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect((capabilities["experimental"] as? [String: Any])?.isEmpty == true)
        #expect((capabilities["elicitation"] as? [String: Any])?.count == 2)
        let tool = Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"prepare_spoken_response","arguments":{"text":"Keep this unchanged."}}}"#.utf8)
        #expect(InitializationCompatibilityTransport.compatibleInitialization(tool) == tool)
    }

    @Test func installedProtocolFixtureInitializesTheRealHelperWithoutExternalShim() throws {
        let process = Process()
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = package.appendingPathComponent(".build/debug/dictaflow-mcp")
        process.arguments = ["--app-id", "com.dictaflow.dev", "--installation-id", UUID().uuidString, "--host", "fixture"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try input.fileHandleForWriting.write(contentsOf: codexInitialization + Data([10]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var received = Data()
        while !received.contains(10), ContinuousClock.now < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0 {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                received.append(chunk)
            }
        }
        let reply = try #require(JSONSerialization.jsonObject(with: received) as? [String: Any])
        #expect(reply["error"] == nil)
        let result = try #require(reply["result"] as? [String: Any])
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "dictaflow-agent-voice")
    }
}
