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
    private var pendingAttachments: [String: Task<VoiceReply, Error>] = [:]
    private var attachmentGeneration = UUID()
    private var requests: [RequestKey: CachedRequest] = [:]
    private var nativeInputs: [NativeTurn: UUID] = [:]

    public init(client: any VoiceBridgeClientProtocol, installationID: UUID, host: String) {
        self.client = client
        self.installationID = installationID
        self.host = host
    }

    public func call(name: String, arguments: [String: Value]) async throws -> VoiceReply {
        try Task.checkCancellation()
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
        let nativeTurn: NativeTurn?
        if let value = arguments["turn_id"] {
            guard let turn = value.stringValue, !turn.isEmpty else {
                throw VoiceError.unavailable("turn_id must be a non-empty string.")
            }
            nativeTurn = NativeTurn(session: nativeSession, turn: turn)
        } else {
            nativeTurn = nil
        }
        let requestID = suppliedRequest ?? UUID()
        let explicitInput = try uuid("input_id", in: arguments)
        let replacesDraft = try uuid("replaces_draft_id", in: arguments)

        requests = requests.filter { Date().timeIntervalSince($0.value.request.issuedAt) < 24 * 60 * 60 }
        let key = RequestKey(session: nativeSession, id: requestID)
        if let retry = try await sendReservedRequest(key: key, tool: name, arguments: arguments) { return retry }

        let session = VoiceSession(installationID: installationID, host: host, sessionID: nativeSession)
        let attachment = try await attachIfNeeded(session)
        // A concurrent identical call may have reserved this key while the
        // attachment was acquired. Reuse its envelope instead of building a
        // competing one: this stretch holds no await, so actor isolation
        // keeps the recheck and the reservation below atomic.
        if let retry = try await sendReservedRequest(key: key, tool: name, arguments: arguments) { return retry }
        let input = operation == .prompt ? nil : explicitInput ?? nativeTurn.flatMap { nativeInputs[$0] }
        // Without a remembered mapping, the persisted native turn in the store
        // may still resolve the input. Resolution there requires the valid
        // attachment above and still respects input closure after reconnect.
        // Stop and Interrupt may also arrive with only a session identity
        // from hosts that document no turn ID; the store then addresses the
        // session's current interaction under the validated attachment.
        guard operation == .prompt || input != nil || nativeTurn != nil
                || operation == .stop || operation == .interrupt else {
            throw VoiceError.unavailable("An active input_id is required. Begin a new prompt after reconnecting; never substitute a newer turn's ID.")
        }
        var request = VoiceRequest(requestID: requestID, session: session, operation: operation,
                                   attachment: attachment, inputID: input,
                                   text: arguments["text"]?.stringValue,
                                   replacesDraftID: replacesDraft,
                                   expectedRevision: arguments["expected_revision"]?.intValue,
                                   nativeTurnID: nativeTurn?.turn,
                                   promptText: operation == .prompt ? arguments["prompt"]?.stringValue : nil)
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
            retireAttachment(for: nativeSession, matching: request.attachment)
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

    /// Resends the envelope reserved for `key` when another call already
    /// claimed it. Returns nil when no reservation exists and the caller must
    /// build a new envelope.
    private func sendReservedRequest(key: RequestKey, tool: String, arguments: [String: Value]) async throws -> VoiceReply? {
        guard let cached = requests[key] else { return nil }
        guard cached.tool == tool, cached.arguments == arguments else {
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

    public func heartbeat() async {
        for (nativeSession, attachment) in attachments {
            let session = VoiceSession(installationID: installationID, host: host, sessionID: nativeSession)
            do {
                let reply = try await send(VoiceRequest(session: session, operation: .heartbeat, attachment: attachment))
                if !reply.accepted { retireAttachment(for: nativeSession, matching: attachment) }
            } catch { return }
        }
    }

    private func attachIfNeeded(_ session: VoiceSession) async throws -> VoiceAttachment {
        try Task.checkCancellation()
        let key = session.sessionID
        if let attachment = attachments[key] { return attachment }
        let generation = attachmentGeneration
        let pending: Task<VoiceReply, Error>
        if let existing = pendingAttachments[key] {
            pending = existing
        } else {
            pending = Task {
                defer {
                    if generation == attachmentGeneration { pendingAttachments[key] = nil }
                }
                let reply = try await send(VoiceRequest(session: session, operation: .attach))
                if generation == attachmentGeneration, reply.accepted, let attachment = reply.attachment {
                    attachments[key] = attachment
                }
                return reply
            }
            pendingAttachments[key] = pending
        }
        let reply = try await pending.value
        try Task.checkCancellation()
        guard generation == attachmentGeneration else {
            throw VoiceError.unavailable("The app connection changed while attaching. Begin a new prompt for speech.")
        }
        guard reply.accepted, let attachment = reply.attachment else {
            throw VoiceError.unavailable("Could not attach to DictaFlow: \(reply.code). Finish the written answer normally.")
        }
        return attachment
    }

    private func send(_ request: VoiceRequest) async throws -> VoiceReply {
        try Task.checkCancellation()
        do { return try await client.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { retireAttachments(); throw error }
    }

    private func retireAttachments() {
        attachmentGeneration = UUID()
        pendingAttachments.removeAll()
        attachments.removeAll()
        nativeInputs.removeAll()
    }

    /// Drops one session's cached attachment and native-turn mappings when it still matches.
    private func retireAttachment(for session: String, matching attachment: VoiceAttachment?) {
        guard let attachment, attachments[session] == attachment else { return }
        attachments[session] = nil
        nativeInputs = nativeInputs.filter { $0.key.session != session }
    }

    private func uuid(_ key: String, in arguments: [String: Value]) throws -> UUID? {
        guard let value = arguments[key] else { return nil }
        guard let text = value.stringValue, let id = UUID(uuidString: text) else {
            throw VoiceError.unavailable("\(key) must be a UUID string.")
        }
        return id
    }
}
