import Foundation

public struct VoiceSession: Codable, Equatable, Hashable, Sendable {
    public let installationID: UUID
    public let host: String
    public let sessionID: String

    public init(installationID: UUID, host: String, sessionID: String) {
        self.installationID = installationID
        self.host = host
        self.sessionID = sessionID
    }
}

/// Transport identity is deliberately separate from the logical host session.
public struct VoiceAttachment: Codable, Equatable, Sendable {
    public let id: UUID
    public let epoch: Int
    public init(id: UUID, epoch: Int) { self.id = id; self.epoch = epoch }
}

public enum VoiceOperation: String, Codable, Sendable {
    case attach, heartbeat, prompt, prepare, stop, interrupt, status
}

public struct VoiceRequest: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var requestID: UUID
    public var issuedAt: Date = Date()
    public var session: VoiceSession
    public var operation: VoiceOperation
    public var attachment: VoiceAttachment?
    public var inputID: UUID?
    public var text: String?
    public var replacesDraftID: UUID?
    public var expectedRevision: Int?

    public init(requestID: UUID = UUID(), session: VoiceSession, operation: VoiceOperation,
                attachment: VoiceAttachment? = nil, inputID: UUID? = nil, text: String? = nil,
                replacesDraftID: UUID? = nil, expectedRevision: Int? = nil) {
        self.requestID = requestID; self.session = session; self.operation = operation
        self.attachment = attachment; self.inputID = inputID; self.text = text
        self.replacesDraftID = replacesDraftID; self.expectedRevision = expectedRevision
    }
}

public enum VoiceState: String, Codable, Sendable {
    case open, prepared, awaitingCompletion, queued, synthesizing, playing, completed
    case skippedMissingDraft, interrupted, cancelled, expired, superseded, failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .skippedMissingDraft, .interrupted, .cancelled, .expired, .superseded, .failed: true
        default: false
        }
    }
}

public struct VoiceReply: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var code: String
    public var attachment: VoiceAttachment?
    public var inputID: UUID?
    public var draftID: UUID?
    public var revision: Int?
    public var state: VoiceState?
    public var message: String

    public init(accepted: Bool, code: String, attachment: VoiceAttachment? = nil, inputID: UUID? = nil,
                draftID: UUID? = nil, revision: Int? = nil, state: VoiceState? = nil, message: String = "") {
        self.accepted = accepted; self.code = code; self.attachment = attachment; self.inputID = inputID
        self.draftID = draftID; self.revision = revision; self.state = state; self.message = message
    }
}

public struct VoiceLimits: Sendable {
    public var retryRetention: TimeInterval = 24 * 60 * 60
    public var attachmentLease: TimeInterval = 30
    public var preparedLifetime: TimeInterval = 5 * 60
    public var queueLifetime: TimeInterval = 5 * 60
    public var maxCharacters = 8_000
    public var maxPendingPerSession = 5
    public var maxPending = 50
    public init() {}
}

public struct VoiceDraft: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var inputID: UUID
    public var session: VoiceSession
    public var revision: Int
    public var text: String
    public var state: VoiceState
    public var createdAt: Date
    public var admittedAt: Date?
    public var failure: String?
}

public enum VoiceInstructions {
    public static func prompt(inputID: UUID) -> String {
        """
        DictaFlow Agent Voice input_id: \(inputID.uuidString).
        Immediately before each final written response, call prepare_spoken_response with a conversational rendition of your answer.
        Explain the useful result, important reasoning, caveats, and next actions naturally for listening.
        Preserve material details. Adapt length to the answer; do not force a tiny summary or read code, tables, or URLs aloud.
        Keep the written answer clean: no spoken-output tags or appended speech transcript.
        If a hook asks you to continue or you discover a material correction, update the rendition before finishing again.
        For an existing draft, use get_speech_status with a fresh request_id to obtain its current draft_id and revision.
        Replace it explicitly using replaces_draft_id and expected_revision; use a fresh request_id for that replacement.
        If a new prompt hook supplies a new input_id, use that newest input instead of the previous one.
        If preparation fails, finish the written answer normally without repair loops.
        Preparation does not authorize playback. DictaFlow manages completion eligibility and audio.
        """
    }
}
