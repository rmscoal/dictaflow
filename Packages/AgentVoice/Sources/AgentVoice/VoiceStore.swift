import CryptoKit
import Foundation
import GRDB

/// One store per app identity. This database is separate from recording history.
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
        try migrator.migrate(database)
        // Recovery never restarts speech. Retain closed inputs and receipts for retry handling.
        try database.write { db in
            try db.execute(sql: "UPDATE inputs SET state = ? WHERE state NOT IN (?, ?, ?, ?, ?, ?, ?)",
                           arguments: [VoiceState.interrupted.rawValue, "completed", "skippedMissingDraft", "interrupted", "cancelled", "expired", "superseded", "failed"])
            try db.execute(sql: "UPDATE sessions SET attachment = NULL, connection = NULL, lease = 0")
            try db.execute(sql: "UPDATE inputs SET host_closed = 1")
            let cutoff = Date().addingTimeInterval(-limits.retryRetention).timeIntervalSince1970
            try db.execute(sql: "DELETE FROM receipts WHERE created < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM inputs WHERE created < ?", arguments: [cutoff])
        }
    }

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
            try expire(db, now: now)
            guard request.version == 1 else { return reject("unsupported_version") }
            guard request.issuedAt <= now.addingTimeInterval(60),
                  now.timeIntervalSince(request.issuedAt) < limits.retryRetention else { return reject("request_expired") }
            guard !request.session.host.isEmpty, request.session.host.count <= 80,
                  !request.session.sessionID.isEmpty, request.session.sessionID.count <= 256 else { return reject("invalid_session") }

            let reply: VoiceReply
            if request.operation == .attach {
                reply = try attach(request, key: key, connectionID: connectionID, now: now, db: db)
            } else {
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

    public func drafts(now: Date = Date()) throws -> [VoiceDraft] {
        try database.write { db in
            try expire(db, now: now)
            return try allDrafts(db)
        }
    }

    /// Only an explicit app UI action may use this path. It is absent from the MCP contract.
    /// It creates a playback attempt without reopening or claiming host completion for an input.
    public func authorizeByUser(draftID: UUID, now: Date = Date()) throws -> VoiceDraft {
        try database.write { db in
            try expire(db, now: now)
            guard var draft = try allDrafts(db).first(where: { $0.id == draftID }),
                  [.prepared, .awaitingCompletion, .completed, .failed, .cancelled].contains(draft.state),
                  !draft.text.isEmpty else { throw VoiceError.unavailable("This rendition is no longer available.") }
            let pending = try allDrafts(db).filter { [.queued, .synthesizing, .playing].contains($0.state) }
            guard pending.count < limits.maxPending,
                  pending.filter({ $0.session == draft.session }).count < limits.maxPendingPerSession else {
                throw VoiceError.unavailable("The speech queue is full.")
            }
            // Each explicit retry gets its own attempt identity. Host input remains closed.
            draft.id = UUID(); draft.state = .queued; draft.admittedAt = now; draft.failure = nil
            try save(draft, db: db)
            try db.execute(sql: "UPDATE inputs SET host_closed = 1 WHERE id = ?", arguments: [draft.inputID.uuidString])
            return draft
        }
    }

    public func nextJob(now: Date = Date()) throws -> VoiceDraft? {
        try database.write { db in
            try expire(db, now: now)
            let pending = try allDrafts(db).filter { $0.state == .queued }
                .sorted { ($0.admittedAt ?? $0.createdAt) < ($1.admittedAt ?? $1.createdAt) }
            guard var draft = pending.first(where: { $0.session != lastScheduledSession }) ?? pending.first else { return nil }
            lastScheduledSession = draft.session
            draft.state = .synthesizing
            try save(draft, db: db)
            return draft
        }
    }

    @discardableResult
    public func transition(_ id: UUID, from: VoiceState, to: VoiceState, failure: String? = nil, now: Date = Date()) throws -> Bool {
        try database.write { db in
            try expire(db, now: now)
            guard var draft = try allDrafts(db).first(where: { $0.id == id }), draft.state == from else { return false }
            draft.state = to; draft.failure = failure
            try save(draft, db: db)
            return true
        }
    }

    public func cancelAll() throws {
        try database.write { db in
            for var draft in try allDrafts(db) where !draft.state.isTerminal {
                draft.state = .cancelled
                try save(draft, db: db)
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

    private func attach(_ request: VoiceRequest, key: String, connectionID: UUID, now: Date, db: Database) throws -> VoiceReply {
        let existing = try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE key = ?", arguments: [key])
        if let existing, existing["lease"] as Double > now.timeIntervalSince1970 {
            return reject("session_already_attached")
        }
        try closeInputs(key, state: .interrupted, db: db)
        let attachment = VoiceAttachment(id: UUID(), epoch: (existing?["epoch"] as Int? ?? 0) + 1)
        try db.execute(sql: "INSERT OR REPLACE INTO sessions VALUES (?, ?, ?, ?, ?)",
                       arguments: [key, attachment.epoch, attachment.id.uuidString, connectionID.uuidString, now.addingTimeInterval(limits.attachmentLease).timeIntervalSince1970])
        return VoiceReply(accepted: true, code: "attached", attachment: attachment,
                          message: "Automatic playback is unavailable: host completion has not been qualified.")
    }

    private func apply(_ request: VoiceRequest, key: String, now: Date, db: Database) throws -> VoiceReply {
        if request.operation == .heartbeat {
            try db.execute(sql: "UPDATE sessions SET lease = ? WHERE key = ?", arguments: [now.addingTimeInterval(limits.attachmentLease).timeIntervalSince1970, key])
            return VoiceReply(accepted: true, code: "alive")
        }
        if request.operation == .prompt {
            // Only this operation creates inputs. Preparation and delayed retries cannot recreate them.
            try closeInputs(key, state: .superseded, db: db)
            let inputID = UUID()
            try db.execute(sql: "INSERT INTO inputs (id, session, state, created, draft) VALUES (?, ?, ?, ?, NULL)",
                           arguments: [inputID.uuidString, key, VoiceState.open.rawValue, now.timeIntervalSince1970])
            return VoiceReply(accepted: true, code: "input_opened", inputID: inputID, state: .open,
                              message: VoiceInstructions.prompt(inputID: inputID))
        }
        guard let inputID = request.inputID,
              let row = try Row.fetchOne(db, sql: "SELECT * FROM inputs WHERE id = ? AND session = ?", arguments: [inputID.uuidString, key]),
              let state = VoiceState(rawValue: row["state"]) else { return reject("unknown_input") }
        var draft = try (row["draft"] as Data?).map { try decoder.decode(VoiceDraft.self, from: $0) }
        draft?.state = state
        if request.operation == .status { return response(draft, state: state, code: "status", inputID: inputID) }
        guard !state.isTerminal else { return reject("input_closed") }
        guard request.operation == .interrupt || row["host_closed"] as Int == 0 else { return reject("input_closed") }
        switch request.operation {
        case .prepare:
            guard state == .open || state == .prepared || state == .awaitingCompletion,
                  let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  text.count <= limits.maxCharacters else { return reject("invalid_or_frozen_rendition") }
            if let draft {
                guard request.replacesDraftID == draft.id, request.expectedRevision == draft.revision else { return reject("replacement_conflict") }
            } else if request.replacesDraftID != nil || request.expectedRevision != nil { return reject("replacement_conflict") }
            if draft == nil {
                let pending = try allDrafts(db).filter { !$0.state.isTerminal }
                guard pending.count < limits.maxPending,
                      pending.filter({ $0.session == request.session }).count < limits.maxPendingPerSession else { return reject("queue_full") }
            }
            let nextDraft = VoiceDraft(id: UUID(), inputID: inputID, session: request.session, revision: (draft?.revision ?? 0) + 1,
                               text: text, state: .prepared, createdAt: draft?.createdAt ?? now)
            try save(nextDraft, db: db)
            return response(nextDraft, state: .prepared, code: "prepared", inputID: inputID)
        case .stop:
            guard [.open, .prepared, .awaitingCompletion].contains(state) else { return reject("input_frozen") }
            // A model-callable Stop is an observation, never completion authorization.
            let next: VoiceState = draft == nil ? .skippedMissingDraft : .awaitingCompletion
            if var draft { draft.state = next; try save(draft, db: db) }
            else { try db.execute(sql: "UPDATE inputs SET state = ?, host_closed = 1 WHERE id = ?", arguments: [next.rawValue, inputID.uuidString]) }
            return response(draft, state: next, code: "completion_unverified", inputID: inputID)
        case .interrupt:
            if var draft { draft.state = .interrupted; try save(draft, db: db) }
            else { try db.execute(sql: "UPDATE inputs SET state = ? WHERE id = ?", arguments: [VoiceState.interrupted.rawValue, inputID.uuidString]) }
            try db.execute(sql: "UPDATE inputs SET host_closed = 1 WHERE id = ?", arguments: [inputID.uuidString])
            return response(draft, state: .interrupted, code: "interrupted", inputID: inputID)
        default: return reject("invalid_operation")
        }
    }

    private func closeInputs(_ key: String, state: VoiceState, db: Database) throws {
        for row in try Row.fetchAll(db, sql: "SELECT id, state, draft FROM inputs WHERE session = ?", arguments: [key]) {
            guard let old = VoiceState(rawValue: row["state"]), !old.isTerminal else { continue }
            if let data: Data = row["draft"] {
                var draft = try decoder.decode(VoiceDraft.self, from: data); draft.state = state
                try save(draft, db: db)
            } else { try db.execute(sql: "UPDATE inputs SET state = ? WHERE id = ?", arguments: [state.rawValue, row["id"] as String]) }
        }
    }

    private func expire(_ db: Database, now: Date) throws {
        for var draft in try allDrafts(db) where !draft.state.isTerminal && draft.state != .playing {
            let expired: Bool
            if let admitted = draft.admittedAt { expired = now.timeIntervalSince(admitted) >= limits.queueLifetime }
            else { expired = now.timeIntervalSince(draft.createdAt) >= limits.preparedLifetime }
            if expired { draft.state = .expired; try save(draft, db: db) }
        }
        let cutoff = now.addingTimeInterval(-limits.retryRetention).timeIntervalSince1970
        try db.execute(sql: "DELETE FROM receipts WHERE created < ?", arguments: [cutoff])
        try db.execute(sql: "DELETE FROM inputs WHERE created < ?", arguments: [cutoff])
        // Session epoch tombstones are retained: old attachments never regain mutation rights.
    }

    private func allDrafts(_ db: Database) throws -> [VoiceDraft] {
        try Row.fetchAll(db, sql: "SELECT draft, state FROM inputs WHERE draft IS NOT NULL").map { row in
            var draft = try decoder.decode(VoiceDraft.self, from: row["draft"])
            guard let state = VoiceState(rawValue: row["state"]) else { throw VoiceError.unavailable("Agent Voice storage contains an unknown state. Disable Agent Voice and check its database.") }
            draft.state = state
            return draft
        }
    }

    private func save(_ draft: VoiceDraft, db: Database) throws {
        try db.execute(sql: "UPDATE inputs SET draft = ?, state = ?, host_closed = CASE WHEN ? THEN 1 ELSE host_closed END WHERE id = ?",
                       arguments: [try encoder.encode(draft), draft.state.rawValue, draft.state.isTerminal, draft.inputID.uuidString])
    }

    private func sessionKey(_ session: VoiceSession) throws -> String { String(decoding: try encoder.encode(session), as: UTF8.self) }
    private func reject(_ code: String) -> VoiceReply { VoiceReply(accepted: false, code: code, message: "Finish the written answer normally. Do not retry with a new request ID.") }
    private func response(_ draft: VoiceDraft?, state: VoiceState, code: String, inputID: UUID) -> VoiceReply {
        VoiceReply(accepted: true, code: code, inputID: inputID, draftID: draft?.id, revision: draft?.revision, state: state)
    }
}

public enum VoiceError: Error, LocalizedError, Sendable {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}
