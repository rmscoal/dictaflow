import AgentVoice
import AgentVoiceMCP
import Foundation
import MCP

func argument(_ key: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: key), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

do {
    guard let appID = argument("--app-id"), ["com.dictaflow", "com.dictaflow.dev"].contains(appID),
          let installation = argument("--installation-id").flatMap(UUID.init(uuidString:)),
          let host = argument("--host"), !host.isEmpty else {
        throw VoiceError.unavailable("Usage: dictaflow-mcp --app-id com.dictaflow[.dev] --installation-id UUID --host codex|claude")
    }
    let socketURL = argument("--socket-path").map { URL(fileURLWithPath: $0) } ?? VoicePaths.socketURL(appID: appID)
    let adapter = VoiceAdapter(client: LocalVoiceClient(socketURL: socketURL), installationID: installation, host: host)
    let server = Server(name: "dictaflow-agent-voice", version: "0.1.0", capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in
        let properties: Value = .object([
            "session_id": ["type": "string", "description": "Stable native host session ID."],
            "turn_id": ["type": "string", "description": "Native host turn ID for observation-only lifecycle callbacks. This does not authenticate a hook."],
            "request_id": ["type": "string", "description": "UUID. Reuse unchanged after an unknown-outcome timeout."],
            "input_id": ["type": "string", "description": "UUID returned by on_user_prompt_submit."],
            "text": ["type": "string", "maxLength": 8000],
            "prompt": ["type": "string", "maxLength": 4000, "description": "Optional prompt text for history, when the host supplies it."],
            "replaces_draft_id": ["type": "string"],
            "expected_revision": ["type": "integer", "minimum": 1]
        ])
        let tools = [
            ("on_user_prompt_submit", "Observe a new prompt and return input identity and spoken-rendition instructions. This is not proof the host accepted the prompt."),
            ("prepare_spoken_response", "Prepare a natural spoken rendition before your clean final answer. Never plays audio by itself. On failure finish the written answer without repair loops."),
            ("on_stop", "Observe Stop for the current rendition. DictaFlow applies its user-set admission policy; a corrected revision needs a fresh Stop."),
            ("on_interrupt", "Conservatively cancel speech for an interrupted input. Does not cancel the agent."),
            ("get_speech_status", "Read an input's speech state.")
        ]
        return .init(tools: tools.map { name, description in
            let required: Value
            switch name {
            case "prepare_spoken_response": required = ["session_id", "input_id", "request_id", "text"]
            case "get_speech_status": required = ["session_id", "input_id", "request_id"]
            // turn_id is optional: hosts that cannot supply a native turn ID
            // still open an input; hosts that supply one get durable mapping.
            case "on_user_prompt_submit": required = ["session_id"]
            default: required = ["session_id"]
            }
            // on_stop and on_interrupt require only session_id: hosts without
            // a documented turn ID address the session's current input, and
            // hosts with one may add turn_id or input_id for exact identity.
            let schema: [String: Value] = ["type": "object", "properties": properties, "required": required]
            return Tool(name: name, description: description, inputSchema: .object(schema))
        })
    }
    await server.withMethodHandler(CallTool.self) { params in
        do {
            let reply = try await adapter.call(name: params.name, arguments: params.arguments ?? [:])
            try Task.checkCancellation()
            if params.name == "on_user_prompt_submit", reply.accepted {
                let context: [String: Value] = ["hookSpecificOutput": .object([
                    "hookEventName": "UserPromptSubmit", "additionalContext": .string("DictaFlow session_id: \(params.arguments?["session_id"]?.stringValue ?? ""). Use a fresh UUID request_id for each new operation, and reuse it unchanged only for a timeout retry.\n" + reply.message)
                ])]
                let data = try JSONEncoder().encode(context)
                return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: .object(context))
            }
            if params.name == "on_stop" || params.name == "on_interrupt" {
                // Hook failures remain fail-open, but must be observable rather than looking accepted.
                if !reply.accepted {
                    let notice: [String: Value] = ["systemMessage": .string("DictaFlow: \(reply.code). Speech observation was not applied; finish the written answer normally.")]
                    let data = try JSONEncoder().encode(notice)
                    return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: .object(notice), isError: true)
                }
                return .init(content: [.text(text: "{}", annotations: nil, _meta: nil)], structuredContent: .object([:]))
            }
            let data = try JSONEncoder().encode(reply)
            return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], isError: !reply.accepted)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(content: [.text(text: "DictaFlow unavailable: \(error.localizedDescription) Finish your written answer normally; do not attempt repeated repairs.", annotations: nil, _meta: nil)], isError: true)
        }
    }
    let heartbeat = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { await adapter.heartbeat() }
        }
    }
    try await server.start(transport: InitializationCompatibilityTransport(base: StdioTransport()))
    await server.waitUntilCompleted()
    heartbeat.cancel()
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
