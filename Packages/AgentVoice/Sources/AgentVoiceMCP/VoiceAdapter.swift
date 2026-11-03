import AgentVoice
import Foundation
import MCP

/// Correlates model submissions and native hook observations without treating either as
/// authenticated final-completion evidence. A connection loss retires every attachment.
public actor VoiceAdapter {
    private struct NativeTurn: Hashable { let session: String; let turn: String }
    private struct RequestKey: Hashable { let session: String; let id: UUID }
    private struct CachedRequest {
        let tool: String
        let arguments: [String: Value]
        let request: VoiceRequest
    }

    private let client: any VoiceBridgeClientProtocol
    private let installationID: UUID
    private let host: String
    private var attachments: [String: VoiceAttachment] = [:]
    private var requests: [RequestKey: CachedRequest] = [:]
    private var nativeInputs: [NativeTurn: UUID] = [:]

    public init(client: any VoiceBridgeClientProtocol, installationID: UUID, host: String) {
        self.client = client
        self.installationID = installationID
        self.host = host
    }

    public func call(name: String, arguments: [String: Value]) async throws -> VoiceReply {
        guard let nativeSession = arguments["session_id"]?.stringValue, !nativeSession.isEmpty else {
            throw VoiceError.unavailable("session_id is required. Use the host's stable session identity.")
        }
        let operation: VoiceOperation
        switch name {
        case "on_user_prompt_submit": operation = .prompt
        case "prepare_spoken_response": operation = .prepare
        case "on_stop": operation = .stop
        case "on_interrupt": operation = .interrupt
        case "get_speech_status": operation = .status
        default: throw VoiceError.unavailable("Unknown tool.")
        }
        let suppliedRequest = try uuid("request_id", in: arguments)
        if operation == .prepare || operation == .status {
            guard suppliedRequest != nil else { throw VoiceError.unavailable("request_id is required for this operation.") }
        }
        let requestID = suppliedRequest ?? UUID()
        let explicitInput = try uuid("input_id", in: arguments)
        let replacesDraft = try uuid("replaces_draft_id", in: arguments)

        requests = requests.filter { Date().timeIntervalSince($0.value.request.issuedAt) < 24 * 60 * 60 }
        let key = RequestKey(session: nativeSession, id: requestID)
        if let cached = requests[key] {
            guard cached.tool == name, cached.arguments == arguments else {
                throw VoiceError.unavailable("request_id was already used with different arguments.")
            }
            // Preserve the original envelope for receipt lookup, including after reconnect.
            // A stale reply means no receipt exists for this envelope. Do not reattach or
            // resend with changed identity: the original may still commit, and a new
            // attachment would conflict with that receipt or supersede fresher work.
            // Return an actionable error without retiring the current valid attachment.
            let retry = try await send(cached.request)
            if retry.code == "stale_attachment" {
                return VoiceReply(accepted: false, code: "new_prompt_required", message: "The app connection changed. Finish the written answer normally; begin a new prompt for speech.")
            }
            return retry
        }

        let session = VoiceSession(installationID: installationID, host: host, sessionID: nativeSession)
        let attachment = try await attachIfNeeded(session)
        let nativeTurn = arguments["turn_id"]?.stringValue.map { NativeTurn(session: nativeSession, turn: $0) }
        let input = operation == .prompt ? nil : explicitInput ?? nativeTurn.flatMap { nativeInputs[$0] }
        guard operation == .prompt || input != nil else {
            throw VoiceError.unavailable("An active input_id is required. Begin a new prompt after reconnecting; never substitute a newer turn's ID.")
        }
        var request = VoiceRequest(requestID: requestID, session: session, operation: operation,
                                   attachment: attachment, inputID: input,
                                   text: arguments["text"]?.stringValue,
                                   replacesDraftID: replacesDraft,
                                   expectedRevision: arguments["expected_revision"]?.intValue)
        requests[key] = CachedRequest(tool: name, arguments: arguments, request: request)
        var reply: VoiceReply
        do { reply = try await send(request) }
        catch let error as VoiceBridgeTransportError where operation == .prompt && !error.requestMayHaveBeenAccepted {
            // A dead idle socket can fail before writing a complete frame. This prompt
            // provably was not accepted, so one fresh attachment/retry is safe.
            request.attachment = try await attachIfNeeded(session)
            requests[key] = CachedRequest(tool: name, arguments: arguments, request: request)
            reply = try await send(request)
        }
        if reply.code == "stale_attachment" {
            retireAttachments()
            guard operation == .prompt else {
                return VoiceReply(accepted: false, code: "new_prompt_required", message: "The app connection changed. Finish the written answer normally; begin a new prompt for speech.")
            }
            // The rejected stale request did not create an input or a receipt. Reattach once
            // and deliver this new prompt, rather than silently dropping the first turn.
            request.attachment = try await attachIfNeeded(session)
            requests[key] = CachedRequest(tool: name, arguments: arguments, request: request)
            reply = try await send(request)
        }
        if operation == .prompt, reply.accepted, let input = reply.inputID, let nativeTurn {
            nativeInputs[nativeTurn] = input
        }
        return reply
    }

    public func heartbeat() async {
        for (nativeSession, attachment) in attachments {
            let session = VoiceSession(installationID: installationID, host: host, sessionID: nativeSession)
            do {
                let reply = try await send(VoiceRequest(session: session, operation: .heartbeat, attachment: attachment))
                if !reply.accepted { retireAttachments(); return }
            } catch { return }
        }
    }

    private func attachIfNeeded(_ session: VoiceSession) async throws -> VoiceAttachment {
        if let attachment = attachments[session.sessionID] { return attachment }
        let reply = try await send(VoiceRequest(session: session, operation: .attach))
        guard reply.accepted, let attachment = reply.attachment else {
            throw VoiceError.unavailable("Could not attach to DictaFlow: \(reply.code). Finish the written answer normally.")
        }
        attachments[session.sessionID] = attachment
        return attachment
    }

    private func send(_ request: VoiceRequest) async throws -> VoiceReply {
        do { return try await client.send(request) }
        catch { retireAttachments(); throw error }
    }

    private func retireAttachments() {
        attachments.removeAll()
        nativeInputs.removeAll()
    }

    private func uuid(_ key: String, in arguments: [String: Value]) throws -> UUID? {
        guard let value = arguments[key] else { return nil }
        guard let text = value.stringValue, let id = UUID(uuidString: text) else {
            throw VoiceError.unavailable("\(key) must be a UUID string.")
        }
        return id
    }
}
