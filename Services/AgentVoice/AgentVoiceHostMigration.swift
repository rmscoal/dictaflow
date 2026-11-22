import CryptoKit
import Foundation

/// The durable intent contains only the files for this host profile and is removed
/// as soon as the cutover or its rollback is verified.
struct AgentVoiceHostMigration {
    typealias Host = AgentVoiceHostAvailability.Host
    let host: Host
    let configuration: URL
    let hooks: URL?
    let applicationSupport: URL

    struct Change: Codable, Sendable {
        let url: URL
        let original: Data?
        let candidate: Data
        let permissions: Int16
    }

    struct Journal: Codable, Sendable {
        let arguments: [String]
        let executable: String
        let changes: [Change]
    }

    enum Failure: LocalizedError {
        case manual, hostRunning(String), conflict, manualRecovery(URL), unownedHook
        case interrupted(cause: any Error, recoveryError: any Error)
        case committedCleanup(any Error, canRetry: Bool)

        var errorDescription: String? {
            switch self {
            case .manual: return "Use the manual configuration below to update this profile safely."
            case .hostRunning(let host): return "Quit \(host) and close any sessions using this profile, then try again."
            case .conflict: return "The host configuration changed or is owned by another installation. Review the entries before retrying."
            case .interrupted(let cause, _):
                return "The host update was interrupted. Quit the host and choose Recover setup. If the files changed since the update, review them manually. \(cause.localizedDescription)"
            case .committedCleanup(let error, let canRetry):
                let action = canRetry ? " Quit the host and choose Recover setup to finish." : ""
                return "The host configuration was updated, but Omdo could not finish cleaning up its recovery journal. \(error.localizedDescription)\(action)"
            case .manualRecovery(let journal):
                return "Reconcile the host profile with the manual setup below. Then move the recovery file at \(journal.path) aside before retrying. Keep that file private."
            case .unownedHook: return "A custom voice hook references dictaflow or omdo. Review it in your host before changing the registration."
            }
        }
    }

    private var directory: URL {
        let key = SHA256.hash(data: Data(configuration.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return applicationSupport.appendingPathComponent("Omdo Migration/Host Profiles/\(host.rawValue)-\(key)")
    }

    private var journalURL: URL { directory.appendingPathComponent("pending.json") }

    var hasPendingUpdate: Bool {
        (try? MigrationFiles.attributes(journalURL)) != nil
    }

    func apply(executable: String, arguments: [String],
               prepare: () throws -> [Change],
               verify: ([Change], URL) async throws -> Void,
               checkIdle: () async throws -> Void) async throws {
        try MigrationFiles.makePrivateDirectory(applicationSupport.appendingPathComponent("Omdo Migration"))
        try MigrationFiles.makePrivateDirectory(applicationSupport.appendingPathComponent("Omdo Migration/Host Profiles"))
        let lock = try OmdoMigrationLock(at: directory.appendingPathComponent("profile.lock"))
        defer { withExtendedLifetime(lock) {} }
        try await checkIdle()
        let journal: Journal
        if let data = try Self.read(journalURL) {
            guard let recorded = try? JSONDecoder().decode(Journal.self, from: data),
                  recorded.arguments == arguments, recorded.executable == executable else {
                throw Failure.manualRecovery(journalURL)
            }
            journal = recorded
        } else {
            journal = Journal(arguments: arguments, executable: executable, changes: try prepare())
        }
        guard journal.changes.map(\.url) == [configuration] + (hooks.map { [$0] } ?? []) else { throw Failure.manualRecovery(journalURL) }

        let changes = journal.changes
        var alreadyApplied = true
        for change in changes {
            let current = try Self.read(change.url)
            guard current == change.original || current == change.candidate else { throw Failure.manualRecovery(journalURL) }
            if current != change.candidate { alreadyApplied = false }
        }
        // Validate the candidate in an isolated profile before any live edit.
        try await verify(changes, directory)
        if !hasPendingUpdate {
            try MigrationFiles.replaceDurably(JSONEncoder().encode(journal), at: journalURL)
        }

        do {
            if !alreadyApplied {
                for change in changes {
                    try await checkIdle()
                    let current = try Self.read(change.url)
                    if current == change.candidate { continue }
                    guard current == change.original else { throw Failure.conflict }
                    try Self.write(change.candidate, to: change)
                }
            }
            for change in changes where try Self.read(change.url) != change.candidate {
                throw Failure.conflict
            }
        } catch let applyError {
            // Recovery may only need to finalize a pair from a previous run.
            guard !alreadyApplied else { throw applyError }
            do {
                try await checkIdle()
                // Reverse the order so hooks already refer to the old alias
                // when its registry is restored. Muse writes both together.
                for change in changes.reversed() {
                    let current = try Self.read(change.url)
                    if current == change.original { continue }
                    guard current == change.candidate else { throw Failure.conflict }
                    try Self.write(change.original, to: change)
                }
            } catch {
                throw Failure.interrupted(cause: applyError, recoveryError: error)
            }
            do { try finish() }
            catch where hasPendingUpdate {
                throw Failure.interrupted(cause: applyError, recoveryError: error)
            }
            catch { throw applyError }
            throw applyError
        }

        // The verified pair is committed. A remaining journal can be finalized
        // on retry without rewriting either file.
        do {
            for directory in Set(changes.map { $0.url.deletingLastPathComponent() }) {
                try MigrationFiles.syncDirectory(directory)
            }
            try finish()
        } catch {
            throw Failure.committedCleanup(error, canRetry: hasPendingUpdate)
        }
    }

    private func finish() throws {
        try FileManager.default.removeItem(at: journalURL)
        try MigrationFiles.syncDirectory(directory)
    }

    static func change(at url: URL, original: Data?, candidate: Data) throws -> Change {
        let mode = try MigrationFiles.attributes(url)?[.posixPermissions] as? NSNumber
        return Change(url: url, original: original, candidate: candidate, permissions: mode?.int16Value ?? 0o600)
    }

    static func read(_ url: URL) throws -> Data? {
        guard let attributes = try MigrationFiles.attributes(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else { throw Failure.conflict }
        return try Data(contentsOf: url)
    }

    private static func write(_ data: Data?, to change: Change) throws {
        if let data {
            let parent = change.url.deletingLastPathComponent()
            if try MigrationFiles.attributes(parent) == nil {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try MigrationFiles.requireDirectory(parent)
            try MigrationFiles.replaceDurably(data, at: change.url, permissions: change.permissions)
        } else {
            try FileManager.default.removeItem(at: change.url)
            try MigrationFiles.syncDirectory(change.url.deletingLastPathComponent())
        }
    }

    static func isOwnedHelper(_ command: String, current: String, appID: String) -> Bool {
        if command == current { return true }
        let url = URL(fileURLWithPath: command)
        let suffix = appID == "com.dictaflow" ? ["DictaFlow.app", "Omdo.app"] : ["DictaFlow Dev.app", "Omdo Dev.app"]
        return command.hasPrefix("/") && url.lastPathComponent == "dictaflow-mcp"
            && url.deletingLastPathComponent().lastPathComponent == "MacOS"
            && url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents"
            && suffix.contains(url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent)
    }
}
