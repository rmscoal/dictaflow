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
    case attach, heartbeat, prompt, prepare, skip, stop, interrupt, status
}

/// Contract version 1 is additive: `nativeTurnID` and `promptText` are optional,
/// so envelopes written before they existed still decode. A missing native turn
/// ID is valid; some hosts cannot supply one.
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
    /// Required to resume speech after an explicit agent skip.
    public var skipToken: UUID?
    /// Host-native turn identity when the host supplies one. Persisted on the
    /// interaction so a callback can still identify its turn after a helper
    /// restart. Identification is not reopening rights: an input closed by
    /// disconnect or recovery stays closed, and only its status can be read.
    /// Optional; hosts that cannot supply one omit it.
    public var nativeTurnID: String?
    /// Optional user prompt text for history, supplied explicitly by a hook.
    /// Never scraped from transcripts. Stored truncated to a bounded length.
    public var promptText: String?

    public init(requestID: UUID = UUID(), session: VoiceSession, operation: VoiceOperation,
                attachment: VoiceAttachment? = nil, inputID: UUID? = nil, text: String? = nil,
                replacesDraftID: UUID? = nil, expectedRevision: Int? = nil,
                nativeTurnID: String? = nil, promptText: String? = nil, skipToken: UUID? = nil) {
        self.requestID = requestID; self.session = session; self.operation = operation
        self.attachment = attachment; self.inputID = inputID; self.text = text
        self.replacesDraftID = replacesDraftID; self.expectedRevision = expectedRevision
        self.nativeTurnID = nativeTurnID; self.promptText = promptText; self.skipToken = skipToken
    }
}

public enum VoiceState: String, Codable, Sendable {
    case open, prepared, awaitingCompletion, queued, synthesizing, playing, completed
    case skippedByAgent, skippedMissingDraft, interrupted, cancelled, expired, superseded, failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .skippedByAgent, .skippedMissingDraft, .interrupted, .cancelled, .expired, .superseded, .failed: true
        default: false
        }
    }
}

public struct VoiceReply: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var code: String
    public var attachment: VoiceAttachment?
    public var inputID: UUID?
    /// Current rendition identity. Kept under the historical `draftID` name.
    public var draftID: UUID?
    public var revision: Int?
    public var state: VoiceState?
    public var message: String
    /// Playback attempt created or referenced by this reply, when one exists.
    public var attemptID: UUID?
    /// Same identity as `draftID`, under the rendition name.
    public var renditionID: UUID?
    public var skipToken: UUID?

    public init(accepted: Bool, code: String, attachment: VoiceAttachment? = nil, inputID: UUID? = nil,
                draftID: UUID? = nil, revision: Int? = nil, state: VoiceState? = nil, message: String = "",
                attemptID: UUID? = nil, renditionID: UUID? = nil, skipToken: UUID? = nil) {
        self.accepted = accepted; self.code = code; self.attachment = attachment; self.inputID = inputID
        self.draftID = draftID; self.revision = revision; self.state = state; self.message = message
        self.attemptID = attemptID; self.renditionID = renditionID ?? draftID; self.skipToken = skipToken
    }
}

/// Who may admit automatic playback. Set only through the app-facing store
/// API. It is never part of the model-facing contract, so a model or hook
/// cannot grant itself playback.
public enum VoiceAdmissionPolicy: String, Codable, Equatable, Sendable {
    /// An eligible Stop observation admits the current rendition.
    case automatic
    /// Stop is only recorded. Speech starts only from an explicit Play.
    case manualOnly
}

public struct VoiceLimits: Sendable {
    public var retryRetention: TimeInterval = 24 * 60 * 60
    public var attachmentLease: TimeInterval = 30
    /// Window after a rendition is prepared in which a Stop may auto-admit it.
    /// Manual replay from retained history is not bound by this window.
    public var preparedLifetime: TimeInterval = 5 * 60
    /// How long a queued attempt may wait before it expires unplayed.
    public var queueLifetime: TimeInterval = 5 * 60
    public var maxCharacters = 8_000
    public var maxPendingPerSession = 5
    public var maxPending = 50
    /// How long interactions, renditions, attempts, and events are retained
    /// as history. Independent of queue expiry.
    public var historyRetention: TimeInterval = 30 * 24 * 60 * 60
    public var maxHistoryInteractions = 500
    public var maxPromptCharacters = 4_000
    public init() {}
}

/// Compatibility projection: the current rendition of an interaction, with the
/// state of its latest playback attempt when one exists. New code should use
/// `VoiceRendition`, `VoicePlaybackAttempt`, and `VoiceInteractionRecord`.
///
/// ID semantics are guaranteed and distinct:
/// - In `VoiceStore.drafts()`, `id` is always the stable rendition ID. It does
///   not change when a playback attempt is created, so history rows keyed by
///   it stay stable across manual replay.
/// - In the value returned by `VoiceStore.nextJob()`, `id` is the playback
///   attempt ID, because playback transitions fence on attempt identity.
/// `renditionID` and `attemptID` spell out both identities in either case.
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
    public var renditionID: UUID?
    public var attemptID: UUID?

    public init(id: UUID, inputID: UUID, session: VoiceSession, revision: Int, text: String,
                state: VoiceState, createdAt: Date, admittedAt: Date? = nil, failure: String? = nil,
                renditionID: UUID? = nil, attemptID: UUID? = nil) {
        self.id = id; self.inputID = inputID; self.session = session; self.revision = revision
        self.text = text; self.state = state; self.createdAt = createdAt
        self.admittedAt = admittedAt; self.failure = failure
        self.renditionID = renditionID; self.attemptID = attemptID
    }
}

/// One user turn, persisted independently of any single rendition or attempt.
public struct VoiceInteractionRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var session: VoiceSession
    public var nativeTurnID: String?
    public var createdAt: Date
    public var promptText: String?
    public var isSuppressed: Bool
    public var suppressedAt: Date?
    public var stopObservedAt: Date?
    /// Revision endorsed by the most recent Stop, if any. Eligibility is per
    /// revision: preparing a newer revision clears it until a fresh Stop.
    /// Suppressed interactions never carry eligibility; in manual-only mode it
    /// marks the revision ready for explicit replay instead of auto-admission.
    public var stopEligibleRevision: Int?
    public var state: VoiceState
    public var currentRenditionID: UUID?
    public var currentRevision: Int?
    public var hostClosed: Bool
    /// Agent speech decision, independent of attempts and host mutation rights.
    public var skipToken: UUID? = nil
}

/// One immutable spoken rendition. A correction adds a new revision; it never
/// edits an earlier revision in place.
public struct VoiceRendition: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var inputID: UUID
    public var revision: Int
    public var text: String
    public var createdAt: Date
}

public enum VoiceAttemptKind: String, Codable, Equatable, Sendable {
    case automatic, manual, legacy
}

/// One playback attempt for one rendition. Automatic admission creates at
/// most one automatic attempt per revision; manual replay creates separate
/// manual attempts and never reuses an attempt identity.
public struct VoicePlaybackAttempt: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var inputID: UUID
    public var session: VoiceSession
    public var renditionID: UUID
    public var revision: Int
    public var text: String
    public var kind: VoiceAttemptKind
    public var state: VoiceState
    public var createdAt: Date
    public var failure: String?
    /// Whether the owning interaction was suppressed when this record was read.
    public var interactionSuppressed: Bool = false
}

public enum VoiceHistoryEventKind: String, Codable, Equatable, Sendable {
    case promptOpened, renditionPrepared, speechSkipped, stopObserved, autoAdmitted, manualAdmitted
    case suppressed, superseded, playbackStarted, playbackCompleted, playbackFailed
    case playbackCancelled, interrupted, expired, migrated
}

/// Append-only history note. Events explain history; they are not the source
/// of truth for playback state.
public struct VoiceHistoryEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64
    public var inputID: UUID
    public var kind: VoiceHistoryEventKind
    public var at: Date
    public var renditionID: UUID?
    public var attemptID: UUID?
    public var revision: Int?
    public var detail: String?
}

/// Full retained history for one interaction, for detail views.
public struct VoiceHistoryRecord: Codable, Equatable, Sendable, Identifiable {
    public var interaction: VoiceInteractionRecord
    public var renditions: [VoiceRendition]
    public var attempts: [VoicePlaybackAttempt]
    public var events: [VoiceHistoryEvent]
    public var id: UUID { interaction.id }
}

public enum VoiceInstructions {
    public static func prompt(inputID: UUID) -> String {
        """
        Omdo Agent Voice input_id: \(inputID.uuidString).
        Before each final written response, choose whether there is something useful to hear.
        You may skip speech for a simple acknowledgment or routine success confirmation with no substantive result, important caveat, or required next action.
        Base this on the response and conversation context, not prompt length or a minimum word count. Speak substantive answers, unexpected outcomes, failures, blockers, and questions requiring the user's decision, even when brief. Honor explicit requests for spoken confirmation.
        For example, after "stage and commit", "Committed as abc123" can remain written only. "The commit failed because a check found a possible secret" should be spoken.
        To skip, call skip_spoken_response with session_id, this input_id, and a fresh request_id. Omit replaces_draft_id and expected_revision only when no rendition exists; otherwise get current status and supply both.
        Finish the written answer normally without announcing the skip. If skip is unavailable or fails, finish without repair loops.
        Otherwise, immediately before the final written response, call prepare_spoken_response with a conversational rendition of your answer.
        Explain the useful result, important reasoning, caveats, and next actions naturally for listening.
        Preserve material details. Adapt length to the answer; do not force a tiny summary or read code, tables, or URLs aloud.
        Write only the words to be spoken, in the same language as your answer, with a calm, clear, conversational tone.
        A short spoken answer may be one sentence. For longer answers, group related sentences into short paragraphs. Do not pad speech to meet a length target.
        Vary sentence lengths naturally, use contractions where appropriate, and punctuate according to meaning. Preserve uncertainty and what was actually verified.
        Describe commands, symbols, and technical identifiers in natural spoken language when practical. Do not include Markdown, stage directions, pause tags, SSML, or artificial ellipses.
        Explain a code block's purpose or result rather than reading its source. Use enough of a filename to identify it; keep exact commands, full paths, and URLs in the written answer.
        Aim for at most 220 spoken words, leading with the outcome and important caveats. Omdo accepts content without correction retries and may announce a spoken preview of a long response; the submitted text remains in history.
        Send the complete rendition in one prepare_spoken_response call. Omdo handles synthesis chunks; additional preparations replace revisions rather than append speech.
        Keep the written answer clean: no spoken-output tags or appended speech transcript.
        If a hook asks you to continue or you discover a material correction, update the rendition before finishing again.
        For an existing draft, use get_speech_status with a fresh request_id to obtain its current draft_id and revision.
        To resume after an accepted skip, obtain the current skipToken from the skip reply or get_speech_status and pass it as skip_token to preparation, along with any existing draft replacement fields.
        Replace it explicitly using replaces_draft_id and expected_revision; use a fresh request_id for that replacement.
        If a new prompt hook supplies a new input_id, use that newest input instead of the previous one.
        If preparation fails, finish the written answer normally without repair loops.
        Preparation never plays audio by itself. Omdo decides playback from lifecycle and user settings.
        """
    }
}
