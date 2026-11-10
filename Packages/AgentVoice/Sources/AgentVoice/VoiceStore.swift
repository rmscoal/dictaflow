import CryptoKit
import Foundation
import GRDB

/// One store per app identity. This database is separate from recording history.
///
/// Persistence model (migration v3):
/// - `inputs` is one interaction per user turn, with optional native turn ID,
///   bounded prompt text, suppression, and per-revision Stop eligibility.
/// - `renditions` holds immutable rendition revisions; corrections add rows.
/// - `attempts` holds playback attempts, separate from renditions. Automatic
///   admission creates at most one automatic attempt per revision; manual
///   replay creates separate manual attempts with fresh identities.
/// - `events` is an append-only history log. It explains history and is not
///   the source of truth for playback state.
/// - `settings` holds the app-set admission policy. Models cannot change it.
public actor VoiceStore {
    private let database: DatabaseQueue
    private let limits: VoiceLimits
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var lastScheduledSession: VoiceSession?

    public init(url: URL, limits: VoiceLimits = VoiceLimits()) throws {
        self.limits = limits
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excludedDirectory = directory; try excludedDirectory.setResourceValues(values)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        database = try DatabaseQueue(path: url.path, configuration: configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("agentVoice-v1") { db in
            try db.execute(sql: """
                CREATE TABLE sessions (key TEXT PRIMARY KEY, epoch INTEGER NOT NULL, attachment TEXT,
                    connection TEXT, lease REAL NOT NULL DEFAULT 0);
                CREATE TABLE inputs (id TEXT PRIMARY KEY, session TEXT NOT NULL, state TEXT NOT NULL,
                    created REAL NOT NULL, draft BLOB);
                CREATE INDEX inputs_session ON inputs(session);
                CREATE TABLE receipts (session TEXT NOT NULL, id TEXT NOT NULL, fingerprint TEXT NOT NULL,
                    reply BLOB NOT NULL, created REAL NOT NULL, PRIMARY KEY(session, id));
                """)
        }
        migrator.registerMigration("agentVoice-v2-closed-inputs") { db in
            try db.execute(sql: "ALTER TABLE inputs ADD COLUMN host_closed INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "UPDATE inputs SET host_closed = 1 WHERE state IN ('completed', 'skippedMissingDraft', 'interrupted', 'cancelled', 'expired', 'superseded', 'failed')")
        }
        migrator.registerMigration("agentVoice-v3-interactions") { db in
            try db.execute(sql: """
                ALTER TABLE inputs ADD COLUMN native_turn TEXT;
                ALTER TABLE inputs ADD COLUMN prompt_text TEXT;
                ALTER TABLE inputs ADD COLUMN suppressed INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE inputs ADD COLUMN suppressed_at REAL;
                ALTER TABLE inputs ADD COLUMN stop_observed_at REAL;
                ALTER TABLE inputs ADD COLUMN eligible_revision INTEGER;
                CREATE TABLE renditions (id TEXT PRIMARY KEY, input TEXT NOT NULL, revision INTEGER NOT NULL,
                    text TEXT NOT NULL, created REAL NOT NULL, UNIQUE(input, revision));
                CREATE INDEX renditions_input ON renditions(input);
                CREATE TABLE attempts (id TEXT PRIMARY KEY, input TEXT NOT NULL, rendition TEXT NOT NULL,
                    kind TEXT NOT NULL, state TEXT NOT NULL, created REAL NOT NULL, failure TEXT);
                CREATE INDEX attempts_input ON attempts(input);
                CREATE INDEX attempts_rendition ON attempts(rendition);
                CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, input TEXT NOT NULL,
                    kind TEXT NOT NULL, at REAL NOT NULL, rendition TEXT, attempt TEXT,
                    revision INTEGER, detail TEXT);
                CREATE INDEX events_input ON events(input);
                CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT OR IGNORE INTO settings VALUES ('admissionPolicy', 'automatic');
                """)
        }
        migrator.registerMigration("agentVoice-v4-queue-indexes") { db in
            try db.execute(sql: "CREATE INDEX attempts_active ON attempts(state, created) WHERE state IN ('queued', 'synthesizing', 'playing')")
            try db.execute(sql: "CREATE INDEX receipts_created ON receipts(created)")
        }
        try migrator.migrate(database)
        try backfillLegacyDrafts()
        // Recovery never restarts speech: active attempts are interrupted,
        // host mutation closes, and no automatic attempt is ever recreated.
        try database.write { db in
            let now = Date()
            for attempt in try activeAttempts(db) {
                try setAttemptState(attempt, to: .interrupted, db: db)
                try insertEvent(inputID: attempt.inputID, kind: .interrupted, at: now,
                                renditionID: attempt.renditionID, attemptID: attempt.id, revision: attempt.revision, db: db)
            }
            try db.execute(sql: "UPDATE inputs SET state = ? WHERE state IN (?, ?, ?, ?, ?, ?)",
                           arguments: [VoiceState.interrupted.rawValue, "open", "prepared", "awaitingCompletion", "queued", "synthesizing", "playing"])
            try db.execute(sql: "UPDATE inputs SET host_closed = 1")
            try db.execute(sql: "UPDATE sessions SET attachment = NULL, connection = NULL, lease = 0")
            try pruneHistory(db, now: now)
            let cutoff = now.addingTimeInterval(-limits.retryRetention).timeIntervalSince1970
            try db.execute(sql: "DELETE FROM receipts WHERE created < ?", arguments: [cutoff])
        }
    }

    // MARK: - Request handling (model and hook facing)

    public func handle(_ request: VoiceRequest, connectionID: UUID, now: Date = Date()) throws -> VoiceReply {
        let payload = try encoder.encode(request)
        let fingerprint = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let key = try sessionKey(request.session)
        return try database.write { db in
            // An identical stale-attachment retry may only retrieve its original receipt.
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM receipts WHERE session = ? AND id = ?",
                                          arguments: [key, request.requestID.uuidString]),
               now.timeIntervalSince1970 - (row["created"] as Double) < limits.retryRetention {
                guard row["fingerprint"] as String == fingerprint else { return reject("request_conflict") }
                return try decoder.decode(VoiceReply.self, from: row["reply"])
            }
            if request.operation != .heartbeat { try expire(db, now: now) }
            guard request.version == 1 else { return reject("unsupported_version") }
            guard request.issuedAt <= now.addingTimeInterval(60),
                  now.timeIntervalSince(request.issuedAt) < limits.retryRetention else { return reject("request_expired") }
            guard !request.session.host.isEmpty, request.session.host.count <= 80,
                  !request.session.sessionID.isEmpty, request.session.sessionID.count <= 256 else { return reject("invalid_session") }
            if let turn = request.nativeTurnID, turn.count > 256 { return reject("invalid_session") }

            let reply: VoiceReply
            if request.operation == .attach {
                reply = try attach(request, key: key, connectionID: connectionID, now: now, db: db)
            } else {
                // Native-turn resolution happens only after this attachment and
                // session check, and mutations still respect input closure.
                guard let attachment = request.attachment,
                      let session = try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE key = ?", arguments: [key]),
                      session["attachment"] as String? == attachment.id.uuidString,
                      session["epoch"] as Int == attachment.epoch,
                      session["connection"] as String? == connectionID.uuidString,
                      session["lease"] as Double > now.timeIntervalSince1970 else { return reject("stale_attachment") }
                reply = try apply(request, key: key, now: now, db: db)
            }
            try db.execute(sql: "INSERT INTO receipts VALUES (?, ?, ?, ?, ?)",
                           arguments: [key, request.requestID.uuidString, fingerprint, try encoder.encode(reply), now.timeIntervalSince1970])
            return reply
        }
    }

    // MARK: - App-facing policy, suppression, and playback API

    public func admissionPolicy() throws -> VoiceAdmissionPolicy {
        try database.read { db in
            let raw = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'admissionPolicy'")
            return raw.flatMap(VoiceAdmissionPolicy.init(rawValue:)) ?? .automatic
        }
    }

    /// App-only policy control. Switching to manual-only also cancels queued
    /// automatic attempts; generating or playing audio is stopped by the
    /// coordinator, which owns the player.
    public func setAdmissionPolicy(_ policy: VoiceAdmissionPolicy, now: Date = Date()) throws {
        try database.write { db in
            try expire(db, now: now)
            try db.execute(sql: "INSERT OR REPLACE INTO settings VALUES ('admissionPolicy', ?)", arguments: [policy.rawValue])
            if policy == .manualOnly {
                for attempt in try activeAttempts(db) where attempt.kind == .automatic && attempt.state == .queued {
                    try setAttemptState(attempt, to: .cancelled, db: db)
                    try insertEvent(inputID: attempt.inputID, kind: .playbackCancelled, at: now,
                                    renditionID: attempt.renditionID, attemptID: attempt.id,
                                    revision: attempt.revision, detail: "Admission policy changed to manual-only.", db: db)
                    try syncInteractionState(attempt.inputID, db: db)
                }
            }
        }
    }

    /// Persists user suppression for one interaction and cancels its active
    /// attempts, automatic and manual alike. Suppression never re-enables
    /// automatic admission; a later explicit manual replay is still allowed.
    @discardableResult
    public func suppressInteraction(inputID: UUID, now: Date = Date()) throws -> VoiceInteractionRecord {
        try database.write { db in
            try expire(db, now: now)
            guard let interaction = try rowFor(inputID, db: db) else {
                throw VoiceError.unavailable("This response is no longer available.")
            }
            _ = interaction
            try db.execute(sql: "UPDATE inputs SET suppressed = 1, suppressed_at = ?, eligible_revision = NULL WHERE id = ?",
                           arguments: [now.timeIntervalSince1970, inputID.uuidString])
            for attempt in try attemptsFor(inputID, db: db) where [.queued, .synthesizing, .playing].contains(attempt.state) {
                try setAttemptState(attempt, to: .cancelled, db: db)
            }
            try insertEvent(inputID: inputID, kind: .suppressed, at: now, db: db)
            try syncInteractionState(inputID, db: db)
            return try fetchInteraction(inputID, db: db)!
        }
    }

    @discardableResult
    public func suppressInteractionForAttempt(attemptID: UUID, now: Date = Date()) throws -> VoiceInteractionRecord {
        guard let interaction = try interaction(forAttemptID: attemptID) else {
            throw VoiceError.unavailable("This response is no longer available.")
        }
        return try suppressInteraction(inputID: interaction.id, now: now)
    }

    /// Suppresses every interaction that currently holds an active playback
    /// attempt, plus one named interaction (the coordinator's active input),
    /// in a single transaction. The store resolves the targets itself at
    /// execution time, so an attempt admitted after the caller's last read
    /// is still covered — unlike deriving targets from a UI snapshot. An
    /// unknown or already-removed named input is skipped, not an error.
    @discardableResult
    public func suppressActiveSpeech(for inputID: UUID? = nil, now: Date = Date()) throws -> [VoiceInteractionRecord] {
        try database.write { db in
            try expire(db, now: now)
            var targets = Set<UUID>()
            for attempt in try activeAttempts(db) where [.queued, .synthesizing, .playing].contains(attempt.state) {
                targets.insert(attempt.inputID)
            }
            if let inputID, try rowFor(inputID, db: db) != nil {
                targets.insert(inputID)
            }
            var records: [VoiceInteractionRecord] = []
            for id in targets {
                try db.execute(sql: "UPDATE inputs SET suppressed = 1, suppressed_at = ?, eligible_revision = NULL WHERE id = ?",
                               arguments: [now.timeIntervalSince1970, id.uuidString])
                for attempt in try attemptsFor(id, db: db) where [.queued, .synthesizing, .playing].contains(attempt.state) {
                    try setAttemptState(attempt, to: .cancelled, db: db)
                }
                try insertEvent(inputID: id, kind: .suppressed, at: now, db: db)
                try syncInteractionState(id, db: db)
                records.append(try fetchInteraction(id, db: db)!)
            }
            return records
        }
    }

    public func interaction(inputID: UUID) throws -> VoiceInteractionRecord? {
        try database.read { db in try fetchInteraction(inputID, db: db) }
    }

    public func interaction(forAttemptID attemptID: UUID) throws -> VoiceInteractionRecord? {
        try database.read { db in
            guard let attempt = try fetchAttempt(attemptID, db: db) else { return nil }
            return try fetchInteraction(attempt.inputID, db: db)
        }
    }

    public func interactions(limit: Int = 100) throws -> [VoiceInteractionRecord] {
        try database.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM inputs ORDER BY created DESC LIMIT ?",
                                          arguments: [max(0, min(limit, 500))])
            return try ids.compactMap { try fetchInteraction(UUID(uuidString: $0)!, db: db) }
        }
    }

    public func renditions(inputID: UUID) throws -> [VoiceRendition] {
        try database.read { db in try renditionsFor(inputID, db: db) }
    }

    public func attempts(inputID: UUID) throws -> [VoicePlaybackAttempt] {
        try database.read { db in try attemptsFor(inputID, db: db) }
    }

    public func playbackAttempts(limit: Int = 100) throws -> [VoicePlaybackAttempt] {
        try database.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM attempts ORDER BY created DESC LIMIT ?",
                                          arguments: [max(0, min(limit, 500))])
            return try ids.compactMap { try fetchAttempt(UUID(uuidString: $0)!, db: db) }
        }
    }

    public func events(inputID: UUID) throws -> [VoiceHistoryEvent] {
        try database.read { db in try eventsFor(inputID, db: db) }
    }

    public func historyRecords(limit: Int = 100) throws -> [VoiceHistoryRecord] {
        try database.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM inputs ORDER BY created DESC LIMIT ?",
                                          arguments: [max(0, min(limit, 500))])
            return try ids.compactMap { id in
                guard let uuid = UUID(uuidString: id), let interaction = try fetchInteraction(uuid, db: db) else { return nil }
                return VoiceHistoryRecord(interaction: interaction, renditions: try renditionsFor(uuid, db: db),
                                          attempts: try attemptsFor(uuid, db: db), events: try eventsFor(uuid, db: db))
            }
        }
    }

    /// Explicit manual playback for one rendition. Creates a fresh manual
    /// attempt; it never reuses an attempt identity and never clears
    /// suppression or Stop eligibility.
    public func requestManualPlayback(renditionID: UUID, now: Date = Date()) throws -> VoicePlaybackAttempt {
        try database.write { db in
            try expire(db, now: now)
            guard let rendition = try fetchRendition(renditionID, db: db),
                  let interaction = try rowFor(rendition.inputID, db: db) else {
                throw VoiceError.unavailable("This response is no longer available.")
            }
            guard try activeAttempt(renditionID: renditionID, db: db) == nil else {
                throw VoiceError.unavailable("This response is no longer available.")
            }
            guard try activeAttempts(db).count < limits.maxPending,
                  try activeAttempts(db).filter({ $0.session == interaction.session }).count < limits.maxPendingPerSession else {
                throw VoiceError.unavailable("The speech queue is full.")
            }
            let attempt = try createAttempt(rendition: rendition, kind: .manual, now: now, db: db)
            try insertEvent(inputID: rendition.inputID, kind: .manualAdmitted, at: now,
                            renditionID: rendition.id, attemptID: attempt.id, revision: rendition.revision, db: db)
            try syncInteractionState(rendition.inputID, db: db)
            return try fetchAttempt(attempt.id, db: db)!
        }
    }

    /// Deletes one interaction and all its renditions, attempts, and events.
    /// Active attempts are cancelled in the same transaction, so a late
    /// playback callback afterwards finds no attempt and is rejected.
    @discardableResult
    public func deleteInteraction(inputID: UUID, now: Date = Date()) throws -> Bool {
        try database.write { db in
            guard try fetchInteraction(inputID, db: db) != nil else { return false }
            for attempt in try attemptsFor(inputID, db: db) where [.queued, .synthesizing, .playing].contains(attempt.state) {
                try setAttemptState(attempt, to: .cancelled, db: db)
            }
            try db.execute(sql: "DELETE FROM events WHERE input = ?", arguments: [inputID.uuidString])
            try db.execute(sql: "DELETE FROM attempts WHERE input = ?", arguments: [inputID.uuidString])
            try db.execute(sql: "DELETE FROM renditions WHERE input = ?", arguments: [inputID.uuidString])
            try db.execute(sql: "DELETE FROM inputs WHERE id = ?", arguments: [inputID.uuidString])
            return true
        }
    }

    /// Deletes one rendition and its attempts. Active attempts for it are
    /// cancelled in the same transaction, before any late callback can act.
    @discardableResult
    public func deleteRendition(renditionID: UUID, now: Date = Date()) throws -> Bool {
        try database.write { db in
            guard let rendition = try fetchRendition(renditionID, db: db) else { return false }
            for attempt in try attemptsFor(rendition.inputID, db: db)
            where attempt.renditionID == renditionID && [.queued, .synthesizing, .playing].contains(attempt.state) {
                try setAttemptState(attempt, to: .cancelled, db: db)
            }
            try db.execute(sql: "DELETE FROM events WHERE rendition = ?", arguments: [renditionID.uuidString])
            try db.execute(sql: "DELETE FROM attempts WHERE rendition = ?", arguments: [renditionID.uuidString])
            try db.execute(sql: "DELETE FROM renditions WHERE id = ?", arguments: [renditionID.uuidString])
            try syncInteractionState(rendition.inputID, db: db)
            return true
        }
    }

    /// Applies history retention: age first, then the interaction count cap.
    /// Interactions with active attempts are never pruned. Returns deletions.
    @discardableResult
    public func pruneHistory(now: Date = Date()) throws -> Int {
        try database.write { db in try pruneHistory(db, now: now) }
    }

    /// Runs periodic expiry independently of bridge traffic. Reports whether
    /// queue or history changes need to be published to the UI.
    public func performMaintenance(now: Date = Date()) throws -> Bool {
        try database.write { db in try expire(db, now: now) }
    }

    // MARK: - Compatibility queue API for the coordinator

    /// One row per interaction that has a rendition, keyed by the stable
    /// rendition ID. See `VoiceDraft` for the guaranteed ID semantics.
    public func drafts(now: Date = Date()) throws -> [VoiceDraft] {
        try database.write { db in
            try expire(db, now: now)
            let ids = try String.fetchAll(db, sql: "SELECT id FROM inputs ORDER BY created ASC")
            return try ids.compactMap { id in
                guard let uuid = UUID(uuidString: id) else { return nil }
                return try draftProjection(uuid, db: db)
            }
        }
    }

    /// Compatibility wrapper for explicit Play. Accepts a rendition ID from
    /// `drafts()` or an attempt ID from `nextJob()`/a prior Play, and returns
    /// a job-shaped draft whose `id` is the new attempt ID.
    public func authorizeByUser(draftID: UUID, now: Date = Date()) throws -> VoiceDraft {
        let attempt = try database.write { db -> VoicePlaybackAttempt in
            try expire(db, now: now)
            let renditionID: UUID
            if let rendition = try fetchRendition(draftID, db: db) { renditionID = rendition.id }
            else if let prior = try fetchAttempt(draftID, db: db) { renditionID = prior.renditionID }
            else { throw VoiceError.unavailable("This response is no longer available.") }
            // Re-enter requestManualPlayback logic without a nested write.
            guard let rendition = try fetchRendition(renditionID, db: db),
                  let interaction = try rowFor(rendition.inputID, db: db) else {
                throw VoiceError.unavailable("This response is no longer available.")
            }
            guard try activeAttempt(renditionID: renditionID, db: db) == nil else {
                throw VoiceError.unavailable("This response is no longer available.")
            }
            guard try activeAttempts(db).count < limits.maxPending,
                  try activeAttempts(db).filter({ $0.session == interaction.session }).count < limits.maxPendingPerSession else {
                throw VoiceError.unavailable("The speech queue is full.")
            }
            let created = try createAttempt(rendition: rendition, kind: .manual, now: now, db: db)
            try insertEvent(inputID: rendition.inputID, kind: .manualAdmitted, at: now,
                            renditionID: rendition.id, attemptID: created.id, revision: rendition.revision, db: db)
            try syncInteractionState(rendition.inputID, db: db)
            return try fetchAttempt(created.id, db: db)!
        }
        return VoiceDraft(id: attempt.id, inputID: attempt.inputID, session: attempt.session,
                          revision: attempt.revision, text: attempt.text, state: attempt.state,
                          createdAt: attempt.createdAt, admittedAt: attempt.createdAt,
                          renditionID: attempt.renditionID, attemptID: attempt.id)
    }

    /// Claims the oldest queued attempt. The returned draft's `id` is the
    /// attempt ID; playback transitions must use that identity.
    public func nextJob(now: Date = Date()) throws -> VoiceDraft? {
        try database.write { db in
            try expire(db, now: now)
            let queued = try activeAttempts(db).filter { $0.state == .queued }
                .sorted { $0.createdAt < $1.createdAt }
            guard let attempt = queued.first(where: { $0.session != lastScheduledSession }) ?? queued.first else { return nil }
            lastScheduledSession = attempt.session
            try setAttemptState(attempt, to: .synthesizing, db: db)
            try syncInteractionState(attempt.inputID, db: db)
            let claimed = try fetchAttempt(attempt.id, db: db)!
            return VoiceDraft(id: claimed.id, inputID: claimed.inputID, session: claimed.session,
                              revision: claimed.revision, text: claimed.text, state: claimed.state,
                              createdAt: claimed.createdAt, admittedAt: claimed.createdAt,
                              renditionID: claimed.renditionID, attemptID: claimed.id)
        }
    }

    @discardableResult
    public func transition(_ id: UUID, from: VoiceState, to: VoiceState, failure: String? = nil, now: Date = Date()) throws -> Bool {
        try database.write { db in
            try expire(db, now: now)
            guard let attempt = try fetchAttempt(id, db: db), attempt.state == from else { return false }
            try setAttemptState(attempt, to: to, failure: failure, db: db)
            let kind: VoiceHistoryEventKind? = switch to {
            case .playing: .playbackStarted
            case .completed: .playbackCompleted
            case .failed: .playbackFailed
            case .cancelled: .playbackCancelled
            case .expired: .expired
            case .interrupted: .interrupted
            case .superseded: .superseded
            default: nil
            }
            if let kind {
                try insertEvent(inputID: attempt.inputID, kind: kind, at: now, renditionID: attempt.renditionID,
                                attemptID: attempt.id, revision: attempt.revision,
                                detail: failure.map { String($0.prefix(500)) }, db: db)
            }
            try syncInteractionState(attempt.inputID, db: db)
            return true
        }
    }

    /// Attempt-shaped transition alias with an explicit name for new code.
    @discardableResult
    public func transitionAttempt(_ id: UUID, from: VoiceState, to: VoiceState, failure: String? = nil, now: Date = Date()) throws -> Bool {
        try transition(id, from: from, to: to, failure: failure, now: now)
    }

    public func cancelAll(now: Date = Date()) throws {
        try database.write { db in
            for interaction in try allInteractions(db) where !interaction.state.isTerminal {
                for attempt in try attemptsFor(interaction.id, db: db) where [.queued, .synthesizing, .playing].contains(attempt.state) {
                    try setAttemptState(attempt, to: .cancelled, db: db)
                    try insertEvent(inputID: interaction.id, kind: .playbackCancelled, at: now,
                                    renditionID: attempt.renditionID, attemptID: attempt.id, revision: attempt.revision, db: db)
                }
                try db.execute(sql: "UPDATE inputs SET state = ?, host_closed = 1 WHERE id = ?",
                               arguments: [VoiceState.cancelled.rawValue, interaction.id.uuidString])
            }
        }
    }

    public func disconnect(connectionID: UUID) throws {
        try database.write { db in
            let keys = try String.fetchAll(db, sql: "SELECT key FROM sessions WHERE connection = ?", arguments: [connectionID.uuidString])
            for key in keys { try closeInputs(key, state: .interrupted, db: db) }
            try db.execute(sql: "UPDATE sessions SET attachment = NULL, connection = NULL, lease = 0 WHERE connection = ?", arguments: [connectionID.uuidString])
        }
    }

    // MARK: - Private request application

    nonisolated private func attach(_ request: VoiceRequest, key: String, connectionID: UUID, now: Date, db: Database) throws -> VoiceReply {
        let existing = try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE key = ?", arguments: [key])
        let message = "DictaFlow decides playback from lifecycle and user settings."
        if let existing, existing["lease"] as Double > now.timeIntervalSince1970 {
            // The helper may lose its local copy while an attach is in flight.
            // Only the original socket can recover that attachment.
            guard existing["connection"] as String? == connectionID.uuidString,
                  let id = (existing["attachment"] as String?).flatMap(UUID.init(uuidString:)) else {
                return reject("session_already_attached")
            }
            let attachment = VoiceAttachment(id: id, epoch: existing["epoch"])
            return VoiceReply(accepted: true, code: "attached", attachment: attachment, message: message)
        }
        try closeInputs(key, state: .interrupted, db: db)
        let attachment = VoiceAttachment(id: UUID(), epoch: (existing?["epoch"] as Int? ?? 0) + 1)
        try db.execute(sql: "INSERT OR REPLACE INTO sessions VALUES (?, ?, ?, ?, ?)",
                       arguments: [key, attachment.epoch, attachment.id.uuidString, connectionID.uuidString, now.addingTimeInterval(limits.attachmentLease).timeIntervalSince1970])
        return VoiceReply(accepted: true, code: "attached", attachment: attachment, message: message)
    }

    nonisolated private func apply(_ request: VoiceRequest, key: String, now: Date, db: Database) throws -> VoiceReply {
        if request.operation == .heartbeat {
            try db.execute(sql: "UPDATE sessions SET lease = ? WHERE key = ?", arguments: [now.addingTimeInterval(limits.attachmentLease).timeIntervalSince1970, key])
            return VoiceReply(accepted: true, code: "alive")
        }
        if request.operation == .prompt {
            // Only this operation creates inputs. Preparation and delayed retries cannot recreate them.
            try closeInputs(key, state: .superseded, db: db)
            let inputID = UUID()
            let promptText = (request.promptText ?? request.text).map { String($0.prefix(limits.maxPromptCharacters)) }
            try db.execute(sql: """
                INSERT INTO inputs (id, session, state, created, draft, host_closed, native_turn, prompt_text)
                VALUES (?, ?, ?, ?, NULL, 0, ?, ?)
                """, arguments: [inputID.uuidString, key, VoiceState.open.rawValue, now.timeIntervalSince1970,
                                 request.nativeTurnID, promptText])
            try insertEvent(inputID: inputID, kind: .promptOpened, at: now, db: db)
            return VoiceReply(accepted: true, code: "input_opened", inputID: inputID, state: .open,
                              message: VoiceInstructions.prompt(inputID: inputID))
        }
        // Resolve identity: explicit input ID wins; otherwise the persisted
        // native turn mapping for this session. Resolution is not permission:
        // closed inputs below still reject mutation.
        var resolvedInput = request.inputID
        if resolvedInput == nil, let turn = request.nativeTurnID, !turn.isEmpty {
            resolvedInput = try String.fetchOne(db, sql: """
                SELECT id FROM inputs WHERE session = ? AND native_turn = ? ORDER BY created DESC LIMIT 1
                """, arguments: [key, turn]).flatMap(UUID.init(uuidString:))
        }
        if resolvedInput == nil, request.nativeTurnID == nil, request.operation == .stop || request.operation == .interrupt
            || request.operation == .status {
            // Hosts without a native turn identity (documented for Claude
            // Code) address the session's current interaction. This is a
            // resolution rule, not ordering proof: it names the latest input
            // in the same validated session, and closure checks still apply.
            resolvedInput = try String.fetchOne(db, sql: """
                SELECT id FROM inputs WHERE session = ? ORDER BY created DESC LIMIT 1
                """, arguments: [key]).flatMap(UUID.init(uuidString:))
        }
        guard let inputID = resolvedInput,
              let interaction = try rowFor(inputID, db: db), interaction.sessionKey == key else {
            return reject("unknown_input")
        }
        if request.operation == .status {
            let rendition = try currentRendition(inputID, db: db)
            let attempt = try latestAttempt(inputID, db: db)
            return VoiceReply(accepted: true, code: "status", inputID: inputID, draftID: rendition?.id,
                              revision: rendition?.revision, state: interaction.state,
                              attemptID: attempt?.id, renditionID: rendition?.id)
        }
        guard !interaction.state.isTerminal || interaction.state == .completed || interaction.state == .failed
                || interaction.state == .cancelled || interaction.state == .expired else {
            return reject("input_closed")
        }
        switch request.operation {
        case .prepare: return try prepare(request, interaction: interaction, now: now, db: db)
        case .stop: return try stop(request, interaction: interaction, now: now, db: db)
        case .interrupt:
            // A host interrupt names host work only. On a closed input (for
            // example a superseded turn the user is replaying manually) it is
            // stale: it must not cancel the user's own playback attempt.
            guard !interaction.hostClosed else { return reject("input_closed") }
            for attempt in try attemptsFor(inputID, db: db) where [.queued, .synthesizing, .playing].contains(attempt.state) {
                try setAttemptState(attempt, to: .interrupted, db: db)
            }
            try db.execute(sql: "UPDATE inputs SET state = ?, host_closed = 1 WHERE id = ?",
                           arguments: [VoiceState.interrupted.rawValue, inputID.uuidString])
            try insertEvent(inputID: inputID, kind: .interrupted, at: now, db: db)
            let rendition = try currentRendition(inputID, db: db)
            return VoiceReply(accepted: true, code: "interrupted", inputID: inputID, draftID: rendition?.id,
                              revision: rendition?.revision, state: .interrupted, renditionID: rendition?.id)
        default: return reject("invalid_operation")
        }
    }

    nonisolated private func prepare(_ request: VoiceRequest, interaction: InteractionRow, now: Date, db: Database) throws -> VoiceReply {
        let inputID = interaction.id
        guard !interaction.hostClosed else { return reject("input_closed") }
        // The host mutation window is bounded by retry retention. The row
        // itself stays as history and remains manually replayable.
        guard now.timeIntervalSince(interaction.createdAt) < limits.retryRetention else { return reject("input_closed") }
        guard [.open, .prepared, .awaitingCompletion, .queued, .synthesizing, .playing,
               .completed, .failed, .cancelled, .expired].contains(interaction.state),
              let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              text.count <= limits.maxCharacters else { return reject("invalid_or_frozen_rendition") }
        let current = try currentRendition(inputID, db: db)
        if let current {
            guard request.replacesDraftID == current.id, request.expectedRevision == current.revision else {
                return reject("replacement_conflict")
            }
        } else if request.replacesDraftID != nil || request.expectedRevision != nil { return reject("replacement_conflict") }
        if current == nil {
            // Capacity counts other interactions that already hold a pending
            // rendition; retained terminal history never blocks new work.
            let pending = try allInteractions(db).filter {
                $0.id != inputID && !$0.state.isTerminal
                    && (try? currentRendition($0.id, db: db)) != nil
            }
            guard pending.count < limits.maxPending,
                  pending.filter({ $0.session == request.session }).count < limits.maxPendingPerSession else {
                return reject("queue_full")
            }
        }
        // A correction supersedes any active attempt for an older revision.
        // The new revision then waits for a fresh Stop; an earlier Stop made
        // only the previous revision eligible.
        for attempt in try attemptsFor(inputID, db: db) where [.queued, .synthesizing, .playing].contains(attempt.state) {
            try setAttemptState(attempt, to: .superseded, db: db)
            try insertEvent(inputID: inputID, kind: .superseded, at: now, renditionID: attempt.renditionID,
                            attemptID: attempt.id, revision: attempt.revision, db: db)
        }
        let rendition = VoiceRendition(id: UUID(), inputID: inputID, revision: (current?.revision ?? 0) + 1,
                                       text: text, createdAt: now)
        try db.execute(sql: "INSERT INTO renditions VALUES (?, ?, ?, ?, ?)",
                       arguments: [rendition.id.uuidString, inputID.uuidString, rendition.revision,
                                   rendition.text, rendition.createdAt.timeIntervalSince1970])
        try db.execute(sql: "UPDATE inputs SET eligible_revision = NULL WHERE id = ?", arguments: [inputID.uuidString])
        try insertEvent(inputID: inputID, kind: .renditionPrepared, at: now,
                        renditionID: rendition.id, revision: rendition.revision, db: db)
        try syncInteractionState(inputID, db: db)
        let refreshed = try rowFor(inputID, db: db)!
        let awaited = refreshed.stopObservedAt != nil
        return VoiceReply(accepted: true, code: awaited ? "prepared_awaiting_stop" : "prepared",
                          inputID: inputID, draftID: rendition.id, revision: rendition.revision,
                          state: refreshed.state,
                          message: awaited ? "Rendition saved. A fresh Stop is required for this revision." : "",
                          renditionID: rendition.id)
    }

    nonisolated private func stop(_ request: VoiceRequest, interaction: InteractionRow, now: Date, db: Database) throws -> VoiceReply {
        let inputID = interaction.id
        guard !interaction.hostClosed else { return reject("input_closed") }
        guard now.timeIntervalSince(interaction.createdAt) < limits.retryRetention else { return reject("input_closed") }
        guard [.open, .prepared, .awaitingCompletion, .queued, .synthesizing, .playing,
               .completed, .failed, .cancelled, .expired].contains(interaction.state) else {
            return reject("input_frozen")
        }
        try db.execute(sql: "UPDATE inputs SET stop_observed_at = ? WHERE id = ?",
                       arguments: [now.timeIntervalSince1970, inputID.uuidString])
        let rendition = try currentRendition(inputID, db: db)
        try insertEvent(inputID: inputID, kind: .stopObserved, at: now,
                        renditionID: rendition?.id, revision: rendition?.revision, db: db)
        guard let rendition else {
            // Stop before any rendition: the observation is recorded, but it
            // makes nothing eligible. A later rendition awaits a fresh Stop.
            try syncInteractionState(inputID, db: db)
            return VoiceReply(accepted: true, code: "stop_observed_no_rendition", inputID: inputID,
                              state: .awaitingCompletion,
                              message: "Stop observed before a rendition existed. Nothing was admitted.")
        }
        func reply(_ code: String, state: VoiceState, attemptID: UUID? = nil) -> VoiceReply {
            VoiceReply(accepted: true, code: code, inputID: inputID, draftID: rendition.id,
                       revision: rendition.revision, state: state, attemptID: attemptID, renditionID: rendition.id)
        }
        if interaction.suppressed {
            try syncInteractionState(inputID, db: db)
            return reply("stop_suppressed", state: .awaitingCompletion)
        }
        // Eligibility marks the revision a fresh Stop endorsed. It is
        // recorded for every unsuppressed Stop — including manual-only, where
        // it drives the "Response ready" control — and never for suppressed
        // interactions, so a late Stop cannot re-enable automatic speech.
        try db.execute(sql: "UPDATE inputs SET eligible_revision = ? WHERE id = ?",
                       arguments: [rendition.revision, inputID.uuidString])
        let policy = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'admissionPolicy'")
            .flatMap(VoiceAdmissionPolicy.init(rawValue:)) ?? .automatic
        guard policy == .automatic else {
            try syncInteractionState(inputID, db: db)
            return reply("stop_observed_manual_only", state: .awaitingCompletion)
        }
        if let existing = try attemptsFor(inputID, db: db).first(where: { $0.renditionID == rendition.id && $0.kind == .automatic }) {
            try syncInteractionState(inputID, db: db)
            return reply("stop_duplicate", state: existing.state, attemptID: existing.id)
        }
        if let active = try activeAttempt(renditionID: rendition.id, db: db) {
            try syncInteractionState(inputID, db: db)
            return reply("stop_observed_attempt_active", state: active.state, attemptID: active.id)
        }
        guard now.timeIntervalSince(rendition.createdAt) < limits.preparedLifetime else {
            try syncInteractionState(inputID, db: db)
            return reply("stop_observed_stale_rendition", state: .awaitingCompletion)
        }
        guard try activeAttempts(db).count < limits.maxPending,
              try activeAttempts(db).filter({ $0.session == interaction.session }).count < limits.maxPendingPerSession else {
            try syncInteractionState(inputID, db: db)
            return reply("stop_observed_queue_full", state: .awaitingCompletion)
        }
        let attempt = try createAttempt(rendition: rendition, kind: .automatic, now: now, db: db)
        try insertEvent(inputID: inputID, kind: .autoAdmitted, at: now, renditionID: rendition.id,
                        attemptID: attempt.id, revision: rendition.revision, db: db)
        try syncInteractionState(inputID, db: db)
        return reply("auto_admitted", state: .queued, attemptID: attempt.id)
    }

    // MARK: - Private persistence helpers

    private struct InteractionRow {
        var id: UUID; var session: VoiceSession; var sessionKey: String; var state: VoiceState
        var createdAt: Date; var hostClosed: Bool; var nativeTurnID: String?; var promptText: String?
        var suppressed: Bool; var suppressedAt: Date?; var stopObservedAt: Date?; var eligibleRevision: Int?
        var record: VoiceInteractionRecord {
            VoiceInteractionRecord(id: id, session: session, nativeTurnID: nativeTurnID, createdAt: createdAt,
                                   promptText: promptText, isSuppressed: suppressed, suppressedAt: suppressedAt,
                                   stopObservedAt: stopObservedAt, stopEligibleRevision: eligibleRevision,
                                   state: state, currentRenditionID: nil, currentRevision: nil, hostClosed: hostClosed)
        }
    }

    nonisolated private func rowFor(_ id: UUID, db: Database) throws -> InteractionRow? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM inputs WHERE id = ?", arguments: [id.uuidString]) else { return nil }
        return try interactionRow(row, db: db)
    }

    nonisolated private func fetchInteraction(_ id: UUID, db: Database) throws -> VoiceInteractionRecord? {
        guard let row = try rowFor(id, db: db) else { return nil }
        var record = row.record
        let rendition = try currentRendition(id, db: db)
        record.currentRenditionID = rendition?.id
        record.currentRevision = rendition?.revision
        return record
    }

    nonisolated private func allInteractions(_ db: Database) throws -> [InteractionRow] {
        try Row.fetchAll(db, sql: "SELECT * FROM inputs").map { try interactionRow($0, db: db) }
    }

    nonisolated private func interactionRow(_ row: Row, db: Database) throws -> InteractionRow {
        let key = row["session"] as String
        let session = try JSONDecoder().decode(VoiceSession.self, from: Data(key.utf8))
        return InteractionRow(id: UUID(uuidString: row["id"])!, session: session, sessionKey: key,
                              state: VoiceState(rawValue: row["state"]) ?? .failed,
                              createdAt: Date(timeIntervalSince1970: row["created"]),
                              hostClosed: (row["host_closed"] as Int) != 0,
                              nativeTurnID: row["native_turn"], promptText: row["prompt_text"],
                              suppressed: (row["suppressed"] as Int? ?? 0) != 0,
                              suppressedAt: (row["suppressed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                              stopObservedAt: (row["stop_observed_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                              eligibleRevision: row["eligible_revision"])
    }

    nonisolated private func currentRendition(_ inputID: UUID, db: Database) throws -> VoiceRendition? {
        try Row.fetchOne(db, sql: "SELECT * FROM renditions WHERE input = ? ORDER BY revision DESC LIMIT 1",
                         arguments: [inputID.uuidString]).map(renditionRow)
    }

    nonisolated private func fetchRendition(_ id: UUID, db: Database) throws -> VoiceRendition? {
        try Row.fetchOne(db, sql: "SELECT * FROM renditions WHERE id = ?", arguments: [id.uuidString]).map(renditionRow)
    }

    nonisolated private func renditionsFor(_ inputID: UUID, db: Database) throws -> [VoiceRendition] {
        try Row.fetchAll(db, sql: "SELECT * FROM renditions WHERE input = ? ORDER BY revision ASC",
                         arguments: [inputID.uuidString]).map(renditionRow)
    }

    nonisolated private func renditionRow(_ row: Row) -> VoiceRendition {
        VoiceRendition(id: UUID(uuidString: row["id"])!, inputID: UUID(uuidString: row["input"])!,
                       revision: row["revision"], text: row["text"],
                       createdAt: Date(timeIntervalSince1970: row["created"]))
    }

    nonisolated private func fetchAttempt(_ id: UUID, db: Database) throws -> VoicePlaybackAttempt? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM attempts WHERE id = ?", arguments: [id.uuidString]) else { return nil }
        return try attemptRow(row, db: db)
    }

    nonisolated private func attemptsFor(_ inputID: UUID, db: Database) throws -> [VoicePlaybackAttempt] {
        try Row.fetchAll(db, sql: "SELECT * FROM attempts WHERE input = ? ORDER BY created ASC",
                         arguments: [inputID.uuidString]).map { try attemptRow($0, db: db) }
    }

    nonisolated private func activeAttempts(_ db: Database) throws -> [VoicePlaybackAttempt] {
        try Row.fetchAll(db, sql: "SELECT * FROM attempts WHERE state IN ('queued', 'synthesizing', 'playing')")
            .map { try attemptRow($0, db: db) }
    }

    nonisolated private func activeAttempt(renditionID: UUID, db: Database) throws -> VoicePlaybackAttempt? {
        try Row.fetchOne(db, sql: "SELECT * FROM attempts WHERE rendition = ? AND state IN ('queued', 'synthesizing', 'playing')",
                         arguments: [renditionID.uuidString]).map { try attemptRow($0, db: db) }
    }

    public func isActiveAttempt(_ id: UUID) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attempts WHERE id = ? AND state IN ('queued', 'synthesizing', 'playing'))",
                              arguments: [id.uuidString]) ?? false
        }
    }

    nonisolated private func latestAttempt(_ inputID: UUID, db: Database) throws -> VoicePlaybackAttempt? {
        try attemptsFor(inputID, db: db).last
    }

    nonisolated private func attemptRow(_ row: Row, db: Database) throws -> VoicePlaybackAttempt {
        let inputID = UUID(uuidString: row["input"] as String)!
        let interaction = try rowFor(inputID, db: db)
        return VoicePlaybackAttempt(id: UUID(uuidString: row["id"])!, inputID: inputID,
                                    session: interaction?.session ?? VoiceSession(installationID: UUID(), host: "", sessionID: ""),
                                    renditionID: UUID(uuidString: row["rendition"])!,
                                    revision: try renditionRevision(row["rendition"], db: db),
                                    text: try fetchRendition(UUID(uuidString: row["rendition"])!, db: db)?.text ?? "",
                                    kind: VoiceAttemptKind(rawValue: row["kind"]) ?? .legacy,
                                    state: VoiceState(rawValue: row["state"]) ?? .failed,
                                    createdAt: Date(timeIntervalSince1970: row["created"]),
                                    failure: row["failure"], interactionSuppressed: interaction?.suppressed ?? false)
    }

    nonisolated private func renditionRevision(_ id: String, db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT revision FROM renditions WHERE id = ?", arguments: [id]) ?? 0
    }

    nonisolated private func eventsFor(_ inputID: UUID, db: Database) throws -> [VoiceHistoryEvent] {
        try Row.fetchAll(db, sql: "SELECT * FROM events WHERE input = ? ORDER BY seq ASC",
                         arguments: [inputID.uuidString]).map { row in
            VoiceHistoryEvent(id: row["seq"], inputID: inputID,
                              kind: VoiceHistoryEventKind(rawValue: row["kind"]) ?? .migrated,
                              at: Date(timeIntervalSince1970: row["at"]),
                              renditionID: (row["rendition"] as String?).flatMap(UUID.init(uuidString:)),
                              attemptID: (row["attempt"] as String?).flatMap(UUID.init(uuidString:)),
                              revision: row["revision"], detail: row["detail"])
        }
    }

    nonisolated private func draftProjection(_ inputID: UUID, db: Database) throws -> VoiceDraft? {
        guard let interaction = try rowFor(inputID, db: db),
              let rendition = try currentRendition(inputID, db: db) else { return nil }
        let attempt = try latestAttempt(inputID, db: db)
        return VoiceDraft(id: rendition.id, inputID: inputID, session: interaction.session,
                          revision: rendition.revision, text: rendition.text, state: interaction.state,
                          createdAt: rendition.createdAt, admittedAt: attempt?.createdAt,
                          failure: attempt?.failure, renditionID: rendition.id, attemptID: attempt?.id)
    }

    nonisolated private func createAttempt(rendition: VoiceRendition, kind: VoiceAttemptKind, now: Date, db: Database) throws -> VoicePlaybackAttempt {
        let attempt = VoicePlaybackAttempt(id: UUID(), inputID: rendition.inputID,
                                           session: try rowFor(rendition.inputID, db: db)!.session,
                                           renditionID: rendition.id, revision: rendition.revision,
                                           text: rendition.text, kind: kind, state: .queued, createdAt: now)
        try db.execute(sql: "INSERT INTO attempts VALUES (?, ?, ?, ?, ?, ?, NULL)",
                       arguments: [attempt.id.uuidString, rendition.inputID.uuidString, rendition.id.uuidString,
                                   kind.rawValue, VoiceState.queued.rawValue, now.timeIntervalSince1970])
        return attempt
    }

    nonisolated private func setAttemptState(_ attempt: VoicePlaybackAttempt, to state: VoiceState, failure: String? = nil, db: Database) throws {
        try db.execute(sql: "UPDATE attempts SET state = ?, failure = ? WHERE id = ?",
                       arguments: [state.rawValue, failure, attempt.id.uuidString])
    }

    nonisolated private func syncInteractionState(_ inputID: UUID, db: Database) throws {
        guard let interaction = try rowFor(inputID, db: db) else { return }
        let attempts = try attemptsFor(inputID, db: db)
        let rendition = try currentRendition(inputID, db: db)
        let state: VoiceState
        if let active = attempts.last(where: { [.queued, .synthesizing, .playing].contains($0.state) }) {
            state = active.state
        } else if interaction.hostClosed, [.superseded, .interrupted, .cancelled].contains(interaction.state) {
            state = interaction.state
        } else if let rendition, !attempts.contains(where: { $0.renditionID == rendition.id }) {
            // The current revision has never been attempted: it is waiting for
            // preparation completion or a fresh Stop, whatever older revisions did.
            state = interaction.stopObservedAt != nil ? .awaitingCompletion : .prepared
        } else if let latest = attempts.last {
            state = latest.state
        } else if rendition != nil {
            state = interaction.stopObservedAt != nil ? .awaitingCompletion : .prepared
        } else {
            state = interaction.stopObservedAt != nil ? .awaitingCompletion : .open
        }
        try db.execute(sql: "UPDATE inputs SET state = ? WHERE id = ?", arguments: [state.rawValue, inputID.uuidString])
    }

    nonisolated private func insertEvent(inputID: UUID, kind: VoiceHistoryEventKind, at now: Date,
                             renditionID: UUID? = nil, attemptID: UUID? = nil,
                             revision: Int? = nil, detail: String? = nil, db: Database) throws {
        try db.execute(sql: "INSERT INTO events (input, kind, at, rendition, attempt, revision, detail) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       arguments: [inputID.uuidString, kind.rawValue, now.timeIntervalSince1970,
                                   renditionID?.uuidString, attemptID?.uuidString, revision,
                                   detail.map { String($0.prefix(500)) }])
    }

    nonisolated private func closeInputs(_ key: String, state: VoiceState, db: Database) throws {
        let now = Date()
        for interaction in try allInteractions(db) where interaction.sessionKey == key
            && (!interaction.hostClosed || !interaction.state.isTerminal) {
            for attempt in try attemptsFor(interaction.id, db: db) where [.queued, .synthesizing, .playing].contains(attempt.state) {
                if interaction.hostClosed, attempt.kind == .manual { continue }
                try setAttemptState(attempt, to: state, db: db)
                try insertEvent(inputID: interaction.id, kind: state == .superseded ? .superseded : .interrupted,
                                at: now, renditionID: attempt.renditionID, attemptID: attempt.id,
                                revision: attempt.revision, db: db)
            }
            if interaction.hostClosed {
                try syncInteractionState(interaction.id, db: db)
                continue
            }
            // A finished playback does not keep host mutation rights after a
            // new prompt or disconnect. Preserve its historical outcome.
            let closedState = interaction.state.isTerminal ? interaction.state : state
            try db.execute(sql: "UPDATE inputs SET state = ?, host_closed = 1, eligible_revision = NULL WHERE id = ?",
                           arguments: [closedState.rawValue, interaction.id.uuidString])
        }
    }

    @discardableResult
    nonisolated private func expire(_ db: Database, now: Date) throws -> Bool {
        var queueChanged = false
        for attempt in try activeAttempts(db) where [.queued, .synthesizing].contains(attempt.state)
            && now.timeIntervalSince(attempt.createdAt) >= limits.queueLifetime {
            try setAttemptState(attempt, to: .expired, db: db)
            try insertEvent(inputID: attempt.inputID, kind: .expired, at: now, renditionID: attempt.renditionID,
                            attemptID: attempt.id, revision: attempt.revision, db: db)
            try syncInteractionState(attempt.inputID, db: db)
            queueChanged = true
        }
        let cutoff = now.addingTimeInterval(-limits.retryRetention).timeIntervalSince1970
        try db.execute(sql: "DELETE FROM receipts WHERE created < ?", arguments: [cutoff])
        let removed = try pruneHistory(db, now: now)
        // Session epoch tombstones are retained: old attachments never regain mutation rights.
        return queueChanged || removed > 0
    }

    @discardableResult
    nonisolated private func pruneHistory(_ db: Database, now: Date) throws -> Int {
        var deleted = 0
        let inactive = "NOT EXISTS (SELECT 1 FROM attempts WHERE input = inputs.id AND state IN ('queued', 'synthesizing', 'playing'))"
        func delete(_ id: String) throws {
            try db.execute(sql: "DELETE FROM events WHERE input = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM attempts WHERE input = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM renditions WHERE input = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM inputs WHERE id = ?", arguments: [id])
            deleted += 1
        }
        let ageCutoff = now.addingTimeInterval(-limits.historyRetention).timeIntervalSince1970
        for id in try String.fetchAll(db, sql: "SELECT id FROM inputs WHERE created < ? AND \(inactive)", arguments: [ageCutoff]) {
            try delete(id)
        }
        let excess = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inputs")! - limits.maxHistoryInteractions
        if excess > 0 {
            for id in try String.fetchAll(db, sql: "SELECT id FROM inputs WHERE \(inactive) ORDER BY created ASC LIMIT ?", arguments: [excess]) {
                try delete(id)
            }
        }
        return deleted
    }

    /// Converts each retained legacy draft BLOB into one rendition, plus a
    /// legacy attempt only where the old state plainly came from playback.
    /// Expired or missing-draft rows keep no playable text, legacy rows get no
    /// Stop eligibility, and no past lifecycle events are invented.
    nonisolated private func backfillLegacyDrafts() throws {
        try database.write { db in
            for row in try Row.fetchAll(db, sql: "SELECT id, state, draft FROM inputs WHERE draft IS NOT NULL") {
                let inputID = UUID(uuidString: row["id"] as String)!
                guard try fetchRenditionCount(inputID, db: db) == 0,
                      let data: Data = row["draft"],
                      let legacy = try? JSONDecoder().decode(VoiceDraft.self, from: data) else { continue }
                let legacyState = VoiceState(rawValue: row["state"] as String) ?? legacy.state
                if legacyState != .expired, legacyState != .skippedMissingDraft, !legacy.text.isEmpty {
                    try db.execute(sql: "INSERT OR IGNORE INTO renditions VALUES (?, ?, ?, ?, ?)",
                                   arguments: [legacy.id.uuidString, inputID.uuidString, legacy.revision,
                                               legacy.text, legacy.createdAt.timeIntervalSince1970])
                    if [.queued, .synthesizing, .playing, .completed, .failed].contains(legacyState) {
                        try db.execute(sql: "INSERT OR IGNORE INTO attempts VALUES (?, ?, ?, 'legacy', ?, ?, ?)",
                                       arguments: [UUID().uuidString, inputID.uuidString, legacy.id.uuidString,
                                                   legacyState.rawValue,
                                                   (legacy.admittedAt ?? legacy.createdAt).timeIntervalSince1970, legacy.failure])
                    }
                }
                try insertEvent(inputID: inputID, kind: .migrated, at: Date(),
                                renditionID: legacy.id, revision: legacy.revision,
                                detail: "Legacy state: \(legacyState.rawValue)", db: db)
                try db.execute(sql: "UPDATE inputs SET draft = NULL WHERE id = ?", arguments: [inputID.uuidString])
            }
        }
    }

    nonisolated private func fetchRenditionCount(_ inputID: UUID, db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM renditions WHERE input = ?", arguments: [inputID.uuidString]) ?? 0
    }

    nonisolated private func sessionKey(_ session: VoiceSession) throws -> String {
        let keyEncoder = JSONEncoder(); keyEncoder.outputFormatting = [.sortedKeys]
        return String(decoding: try keyEncoder.encode(session), as: UTF8.self)
    }
    nonisolated private func reject(_ code: String) -> VoiceReply { VoiceReply(accepted: false, code: code, message: "Finish the written answer normally. Do not retry with a new request ID.") }
}

public enum VoiceError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case liquidModelUnavailable
    /// The recording exceeds a Liquid transcription limit. Callers retain it
    /// so the user can retry with Whisper or use a shorter clip.
    case inputTooLong(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .inputTooLong(let message): return message
        case .liquidModelUnavailable: return "Download or repair the Liquid audio model in Agent Voice, under Models."
        }
    }
}
