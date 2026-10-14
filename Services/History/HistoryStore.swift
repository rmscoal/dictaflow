import AVFoundation
import Foundation
import GRDB

nonisolated protocol HistoryStoreProtocol: Sendable {
    func initialize() async throws
    func prepareCapture(retention: HistoryRetention) async throws -> HistoryCapture
    func markFinishing(_ id: UUID) async throws
    func finishCapture(_ id: UUID, capture: DictationCapture) async throws -> URL
    func discardCapture(_ id: UUID) async throws
    func releaseAudio(_ id: UUID) async
    func acquireRecording(_ id: UUID) async throws
    func captureURL(_ id: UUID) async throws -> URL
    func acquireAudio(_ id: UUID) async throws -> URL
    func startTranscription(_ id: UUID, configuration: WhisperConfiguration) async throws -> UUID
    func finishTranscription(_ attemptID: UUID, result: WhisperTranscriptionResult?, error: String?) async throws
    func startRefinement(_ transcriptionID: UUID, configuration: RefinementConfiguration, prompt: String) async throws -> UUID
    func finishRefinement(_ attemptID: UUID, result: TranscriptRefinementResult?, error: String?) async throws
    func entries(search: String, limit: Int, offset: Int) async throws -> [HistoryEntry]
    func detail(_ id: UUID) async throws -> HistoryDetail
    func delete(_ id: UUID) async throws
    func deleteAll() async throws
    func countRecordingsExpiring(retention: HistoryRetention, now: Date) async throws -> Int
    func setRetention(_ retention: HistoryRetention) async throws
    func cleanup(now: Date) async throws
}

/// Owns both sides of persistence. File operations cannot share a SQLite
/// transaction, so storage states journal the work needed after an interruption.
/// Synchronous GRDB/file calls run on this actor, never on MainActor or an audio tap.
actor SQLiteHistoryStore: HistoryStoreProtocol {
    private let root: URL
    private let fileManager = FileManager()
    private var database: DatabaseQueue?
    private var hasRecovered = false
    private var audioUsers: [UUID: Int] = [:]

    init(root: URL = SQLiteHistoryStore.defaultDirectory) {
        self.root = root
    }

    nonisolated static var defaultDirectory: URL {
        let appName = Bundle.main.bundleIdentifier == "com.dictaflow" ? "DictaFlow" : "DictaFlow Dev"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appName)/History", isDirectory: true)
    }

    private func open() throws -> DatabaseQueue {
        if let database { return database }
        for directory in [root, root.appendingPathComponent("Staging"), root.appendingPathComponent("Recordings")] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw HistoryStoreError.invalidRecording }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        var excludedRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedRoot.setResourceValues(values)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        let queue = try DatabaseQueue(path: root.appendingPathComponent("history.sqlite").path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("history-v1") { db in
            try db.execute(sql: """
                CREATE TABLE recordings (
                    id TEXT PRIMARY KEY NOT NULL,
                    capturedAt REAL NOT NULL,
                    duration REAL NOT NULL DEFAULT 0,
                    expiresAt REAL NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('capturing', 'finalizing', 'ready', 'deleting')),
                    audioAvailable INTEGER NOT NULL DEFAULT 1
                );
                CREATE INDEX recordings_date ON recordings(capturedAt DESC);
                CREATE INDEX recordings_expiry ON recordings(expiresAt);
                CREATE TABLE transcription_results (
                    id TEXT PRIMARY KEY NOT NULL,
                    recordingID TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                    startedAt REAL NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'failed', 'interrupted')),
                    configuration BLOB NOT NULL,
                    result BLOB,
                    text TEXT,
                    error TEXT
                );
                CREATE INDEX transcription_recording ON transcription_results(recordingID, startedAt DESC);
                CREATE TABLE refinement_results (
                    id TEXT PRIMARY KEY NOT NULL,
                    transcriptionID TEXT NOT NULL REFERENCES transcription_results(id) ON DELETE CASCADE,
                    startedAt REAL NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('running', 'succeeded', 'failed', 'interrupted')),
                    configuration BLOB NOT NULL,
                    prompt TEXT NOT NULL,
                    result BLOB,
                    text TEXT,
                    error TEXT
                );
                CREATE INDEX refinement_transcription ON refinement_results(transcriptionID, startedAt DESC);
                """)
        }
        migrator.registerMigration("history-v2-completion-times") { db in
            try db.execute(sql: "ALTER TABLE transcription_results ADD COLUMN completedAt REAL")
            try db.execute(sql: "ALTER TABLE refinement_results ADD COLUMN completedAt REAL")
        }
        migrator.registerMigration("history-v3-tone-output") { db in
            try db.execute(sql: "ALTER TABLE transcription_results ADD COLUMN finalText TEXT")
            try db.execute(sql: "ALTER TABLE refinement_results ADD COLUMN finalText TEXT")
        }
        try migrator.migrate(queue)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("history.sqlite").path)
        database = queue
        return queue
    }

    private func stagingURL(_ id: UUID) -> URL { root.appendingPathComponent("Staging/\(id.uuidString).m4a") }
    private func audioURL(_ id: UUID) -> URL { root.appendingPathComponent("Recordings/\(id.uuidString).m4a") }

    func initialize() throws {
        guard !hasRecovered else { return }
        let db = try open()
        let rows = try db.read { try Row.fetchAll($0, sql: "SELECT id, state FROM recordings") }
        for row in rows {
            guard let id = UUID(uuidString: row["id"]) else { throw HistoryStoreError.invalidRecording }
            let state: String = row["state"]
            switch state {
            case "capturing", "deleting":
                try removeRecording(id)
            case "finalizing":
                let url = fileManager.fileExists(atPath: audioURL(id).path) ? audioURL(id) : stagingURL(id)
                let duration: Double
                do {
                    let file = try AVAudioFile(forReading: url)
                    duration = Double(file.length) / file.processingFormat.sampleRate
                    guard duration.isFinite, duration > 0 else { throw HistoryStoreError.invalidRecording }
                } catch {
                    // Preserve unreadable finalized audio for explicit deletion; a
                    // temporary I/O failure must not silently discard user data.
                    try db.write { try $0.execute(sql: "UPDATE recordings SET state = 'ready', audioAvailable = 0 WHERE id = ?", arguments: [id.uuidString]) }
                    continue
                }
                _ = try finishCapture(id, capture: DictationCapture(fileURL: url, duration: duration, capturedAt: Date()))
            default:
                if !fileManager.fileExists(atPath: audioURL(id).path) {
                    try db.write { try $0.execute(sql: "UPDATE recordings SET audioAvailable = 0 WHERE id = ?", arguments: [id.uuidString]) }
                }
            }
        }
        try db.write { db in
            for table in ["transcription_results", "refinement_results"] {
                try db.execute(sql: "UPDATE \(table) SET status = 'interrupted', completedAt = ?, error = 'Processing was interrupted. Try again.' WHERE status = 'running'", arguments: [Date().timeIntervalSince1970])
            }
        }
        // Files without an intent row never represent completed, owned history.
        // Remove only UUID-named files in our private staging directory.
        let knownIDs = Set(try db.read { try String.fetchAll($0, sql: "SELECT id FROM recordings") })
        for url in try fileManager.contentsOfDirectory(at: root.appendingPathComponent("Staging"), includingPropertiesForKeys: nil) {
            let name = url.deletingPathExtension().lastPathComponent
            if url.pathExtension == "m4a", UUID(uuidString: name) != nil, !knownIDs.contains(name) {
                try fileManager.removeItem(at: url)
            }
        }
        hasRecovered = true
    }

    func prepareCapture(retention: HistoryRetention) throws -> HistoryCapture {
        guard retention != .off else { throw HistoryStoreError.unavailable }
        try initialize()
        let id = UUID(), now = Date()
        try open().write { db in
            try db.execute(sql: "INSERT INTO recordings (id, capturedAt, expiresAt, state) VALUES (?, ?, ?, 'capturing')", arguments: [id.uuidString, now.timeIntervalSince1970, now.addingTimeInterval(Double(retention.rawValue) * 86400).timeIntervalSince1970])
        }
        audioUsers[id] = 1
        return HistoryCapture(id: id, fileURL: stagingURL(id))
    }

    func markFinishing(_ id: UUID) throws {
        try open().write { db in
            try db.execute(sql: "UPDATE recordings SET state = 'finalizing' WHERE id = ? AND state = 'capturing'", arguments: [id.uuidString])
            guard db.changesCount == 1 else { throw HistoryStoreError.unavailable }
        }
    }

    func finishCapture(_ id: UUID, capture: DictationCapture) throws -> URL {
        let db = try open()
        let state = try db.read { try String.fetchOne($0, sql: "SELECT state FROM recordings WHERE id = ?", arguments: [id.uuidString]) }
        guard state == "finalizing" else { throw HistoryStoreError.unavailable }
        let destination = audioURL(id)
        guard capture.fileURL.standardizedFileURL == stagingURL(id).standardizedFileURL || capture.fileURL.standardizedFileURL == destination.standardizedFileURL else { throw HistoryStoreError.invalidRecording }
        if capture.fileURL != destination { try fileManager.moveItem(at: capture.fileURL, to: destination) }
        try db.write { try $0.execute(sql: "UPDATE recordings SET state = 'ready', duration = ? WHERE id = ? AND state = 'finalizing'", arguments: [capture.duration, id.uuidString]) }
        return destination
    }

    func discardCapture(_ id: UUID) throws {
        // Persist discard intent before deleting so recovery never revives a cancel.
        try open().write { try $0.execute(sql: "UPDATE recordings SET state = 'deleting' WHERE id = ?", arguments: [id.uuidString]) }
        audioUsers[id] = nil
        try removeRecording(id)
    }

    func captureURL(_ id: UUID) throws -> URL {
        for url in [audioURL(id), stagingURL(id)] where fileManager.fileExists(atPath: url.path) { return url }
        throw HistoryStoreError.unavailable
    }

    func acquireRecording(_ id: UUID) throws {
        let exists = try open().read {
            try Bool.fetchOne($0, sql: "SELECT state = 'ready' AND expiresAt > ? FROM recordings WHERE id = ?", arguments: [Date().timeIntervalSince1970, id.uuidString])
        } ?? false
        guard exists else { throw HistoryStoreError.unavailable }
        audioUsers[id, default: 0] += 1
    }

    func acquireAudio(_ id: UUID) throws -> URL {
        try acquireRecording(id)
        guard fileManager.fileExists(atPath: audioURL(id).path) else {
            releaseAudio(id)
            throw HistoryStoreError.unavailable
        }
        return audioURL(id)
    }

    func releaseAudio(_ id: UUID) {
        guard let count = audioUsers[id] else { return }
        audioUsers[id] = count > 1 ? count - 1 : nil
    }

    func startTranscription(_ id: UUID, configuration: WhisperConfiguration) throws -> UUID {
        let attempt = UUID(), settings = try JSONEncoder().encode(configuration)
        try open().write { db in
            guard try Bool.fetchOne(db, sql: "SELECT state = 'ready' FROM recordings WHERE id = ?", arguments: [id.uuidString]) == true else { throw HistoryStoreError.unavailable }
            try db.execute(sql: "INSERT INTO transcription_results (id, recordingID, startedAt, status, configuration) VALUES (?, ?, ?, 'running', ?)", arguments: [attempt.uuidString, id.uuidString, Date().timeIntervalSince1970, settings])
        }
        return attempt
    }

    func finishTranscription(_ attemptID: UUID, result: WhisperTranscriptionResult?, error: String?) throws {
        let payload = try result.map { try JSONEncoder().encode($0) }
        try open().write { db in
            try db.execute(sql: "UPDATE transcription_results SET status = ?, result = ?, text = ?, finalText = ?, error = ?, completedAt = ? WHERE id = ? AND status = 'running' AND recordingID IN (SELECT id FROM recordings WHERE state = 'ready')", arguments: [result == nil ? "failed" : "succeeded", payload, result?.text, result?.insertionText, error, result?.completedAt.timeIntervalSince1970 ?? Date().timeIntervalSince1970, attemptID.uuidString])
            guard db.changesCount == 1 else { throw HistoryStoreError.unavailable }
        }
    }

    func startRefinement(_ transcriptionID: UUID, configuration: RefinementConfiguration, prompt: String) throws -> UUID {
        let attempt = UUID(), settings = try JSONEncoder().encode(configuration)
        try open().write { db in
            guard try Bool.fetchOne(db, sql: "SELECT t.status = 'succeeded' AND r.state = 'ready' FROM transcription_results t JOIN recordings r ON r.id = t.recordingID WHERE t.id = ?", arguments: [transcriptionID.uuidString]) == true else { throw HistoryStoreError.unavailable }
            try db.execute(sql: "INSERT INTO refinement_results (id, transcriptionID, startedAt, status, configuration, prompt) VALUES (?, ?, ?, 'running', ?, ?)", arguments: [attempt.uuidString, transcriptionID.uuidString, Date().timeIntervalSince1970, settings, prompt])
        }
        return attempt
    }

    func finishRefinement(_ attemptID: UUID, result: TranscriptRefinementResult?, error: String?) throws {
        let payload = try result.map { try JSONEncoder().encode($0) }
        try open().write { db in
            try db.execute(sql: "UPDATE refinement_results SET status = ?, result = ?, text = ?, finalText = ?, error = ?, completedAt = ? WHERE id = ? AND status = 'running' AND transcriptionID IN (SELECT t.id FROM transcription_results t JOIN recordings r ON r.id = t.recordingID WHERE r.state = 'ready')", arguments: [result == nil ? "failed" : "succeeded", payload, result?.refinedText, result?.insertionText, error, result?.completedAt.timeIntervalSince1970 ?? Date().timeIntervalSince1970, attemptID.uuidString])
            guard db.changesCount == 1 else { throw HistoryStoreError.unavailable }
        }
    }

    private static let summarySQL = """
        SELECT r.*,
          COALESCE((SELECT COALESCE(f.finalText, f.text) FROM refinement_results f JOIN transcription_results t ON t.id = f.transcriptionID WHERE t.id = (SELECT id FROM transcription_results WHERE recordingID = r.id AND status = 'succeeded' ORDER BY startedAt DESC, id DESC LIMIT 1) AND f.status = 'succeeded' ORDER BY f.startedAt DESC, f.id DESC LIMIT 1),
                   (SELECT COALESCE(t.finalText, t.text) FROM transcription_results t WHERE t.recordingID = r.id AND t.status = 'succeeded' ORDER BY t.startedAt DESC LIMIT 1), '') AS preview,
          COALESCE((SELECT status FROM transcription_results t WHERE t.recordingID = r.id ORDER BY startedAt DESC LIMIT 1), 'unprocessed') AS status
        FROM recordings r
        """

    private func identifier(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw HistoryStoreError.invalidRecording }
        return id
    }

    private func status(_ value: String) throws -> HistoryAttemptStatus {
        guard let status = HistoryAttemptStatus(rawValue: value) else { throw HistoryStoreError.invalidRecording }
        return status
    }

    private func entry(_ row: Row) throws -> HistoryEntry {
        guard let id = UUID(uuidString: row["id"]) else { throw HistoryStoreError.invalidRecording }
        return HistoryEntry(id: id, capturedAt: Date(timeIntervalSince1970: row["capturedAt"]), duration: row["duration"], expiresAt: Date(timeIntervalSince1970: row["expiresAt"]), preview: row["preview"], status: try status(row["status"]), audioAvailable: row["audioAvailable"])
    }

    func entries(search: String, limit: Int, offset: Int) throws -> [HistoryEntry] {
        try open().read { db in
            let rows = try Row.fetchAll(db, sql: Self.summarySQL + "\n" + """
                WHERE r.state = 'ready' AND r.expiresAt > ? AND
                  (? = '' OR EXISTS (SELECT 1 FROM transcription_results t WHERE t.recordingID = r.id AND (instr(lower(COALESCE(t.text, '')), lower(?)) > 0 OR instr(lower(COALESCE(t.finalText, '')), lower(?)) > 0))
                   OR EXISTS (SELECT 1 FROM refinement_results f JOIN transcription_results t ON t.id = f.transcriptionID WHERE t.recordingID = r.id AND (instr(lower(COALESCE(f.text, '')), lower(?)) > 0 OR instr(lower(COALESCE(f.finalText, '')), lower(?)) > 0)))
                ORDER BY r.capturedAt DESC, r.id DESC LIMIT ? OFFSET ?
                """, arguments: [Date().timeIntervalSince1970, search, search, search, search, search, min(max(limit, 1), 100), max(offset, 0)])
            return try rows.map(entry)
        }
    }

    func detail(_ id: UUID) throws -> HistoryDetail {
        try open().read { db in
            guard let row = try Row.fetchOne(db, sql: Self.summarySQL + " WHERE r.id = ? AND r.state = 'ready'", arguments: [id.uuidString]) else { throw HistoryStoreError.unavailable }
            let transcriptions = try Row.fetchAll(db, sql: "SELECT * FROM transcription_results WHERE recordingID = ? ORDER BY startedAt DESC, id DESC", arguments: [id.uuidString]).map { row in
                HistoryTranscription(id: try identifier(row["id"]), startedAt: Date(timeIntervalSince1970: row["startedAt"]), status: try status(row["status"]), configuration: try JSONDecoder().decode(WhisperConfiguration.self, from: row["configuration"]), result: try (row["result"] as Data?).map { try JSONDecoder().decode(WhisperTranscriptionResult.self, from: $0) }, errorMessage: row["error"])
            }
            let refinements = try Row.fetchAll(db, sql: "SELECT f.* FROM refinement_results f JOIN transcription_results t ON t.id = f.transcriptionID WHERE t.recordingID = ? ORDER BY f.startedAt DESC, f.id DESC", arguments: [id.uuidString]).map { row in
                HistoryRefinement(id: try identifier(row["id"]), transcriptionID: try identifier(row["transcriptionID"]), startedAt: Date(timeIntervalSince1970: row["startedAt"]), status: try status(row["status"]), configuration: try JSONDecoder().decode(RefinementConfiguration.self, from: row["configuration"]), prompt: row["prompt"], result: try (row["result"] as Data?).map { try JSONDecoder().decode(TranscriptRefinementResult.self, from: $0) }, errorMessage: row["error"])
            }
            return HistoryDetail(entry: try entry(row), transcriptions: transcriptions, refinements: refinements)
        }
    }

    func delete(_ id: UUID) throws {
        guard audioUsers[id] == nil else { throw HistoryStoreError.inUse }
        try open().write { try $0.execute(sql: "UPDATE recordings SET state = 'deleting' WHERE id = ?", arguments: [id.uuidString]) }
        try removeRecording(id)
    }

    func deleteAll() throws {
        guard audioUsers.isEmpty else { throw HistoryStoreError.inUse }
        try open().write { try $0.execute(sql: "UPDATE recordings SET state = 'deleting'") }
        try cleanup(now: Date())
    }

    private func removeRecording(_ id: UUID) throws {
        for url in [stagingURL(id), audioURL(id)] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try open().write { try $0.execute(sql: "DELETE FROM recordings WHERE id = ?", arguments: [id.uuidString]) }
    }

    func countRecordingsExpiring(retention: HistoryRetention, now: Date) throws -> Int {
        guard retention != .off else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(retention.rawValue) * 86400)
        return try open().read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM recordings WHERE state = 'ready' AND capturedAt <= ?", arguments: [cutoff.timeIntervalSince1970]) ?? 0
        }
    }

    func setRetention(_ retention: HistoryRetention) throws {
        guard retention != .off else { return }
        try open().write { try $0.execute(sql: "UPDATE recordings SET expiresAt = capturedAt + ? WHERE state != 'deleting'", arguments: [retention.rawValue * 86400]) }
    }

    func cleanup(now: Date) throws {
        let rows = try open().read { try Row.fetchAll($0, sql: "SELECT id FROM recordings WHERE state = 'deleting' OR (state = 'ready' AND expiresAt <= ?)", arguments: [now.timeIntervalSince1970]) }
        for row in rows {
            guard let id = UUID(uuidString: row["id"]) else { throw HistoryStoreError.invalidRecording }
            if audioUsers[id] == nil { try delete(id) }
        }
    }
}
