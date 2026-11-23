import AgentVoice
import Darwin
import Foundation
import GRDB
import OSLog

nonisolated struct ApplicationSupportPaths: Sendable {
    let applicationSupport: URL
    let bundleID: String

    static var current: Self {
        Self(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
             bundleID: Bundle.main.bundleIdentifier == "com.dictaflow" ? "com.dictaflow" : "com.dictaflow.dev")
    }

    var isRelease: Bool { bundleID == "com.dictaflow" }
    var legacy: URL { applicationSupport.appendingPathComponent(isRelease ? "DictaFlow" : "DictaFlow Dev", isDirectory: true) }
    var current: URL { applicationSupport.appendingPathComponent(isRelease ? "Omdo" : "Omdo Dev", isDirectory: true) }
    var legacySharedModels: URL { applicationSupport.appendingPathComponent("DictaFlow/Models", isDirectory: true) }
    var sharedModels: URL { isRelease ? current.appendingPathComponent("Models", isDirectory: true) : legacySharedModels }
    var migrationDirectory: URL { applicationSupport.appendingPathComponent("Omdo Migration", isDirectory: true) }
    var storageWork: URL { migrationDirectory.appendingPathComponent(bundleID, isDirectory: true) }
    var uncommittedData: URL { storageWork.appendingPathComponent("Previous attempt", isDirectory: true) }

    func legacyArtifacts() -> [URL] {
        (["History", "Prompts", "AgentVoice", "Models/Liquid"].map { legacy.appendingPathComponent($0) } + [uncommittedData])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Imports only verified assets. A model failure is independent of the private data stores.
nonisolated struct LiquidModelMigration: Sendable {
    enum Issue: LocalizedError, Equatable, Sendable {
        case insufficientSpace, incomplete, copyFailed

        var errorDescription: String? {
            switch self {
            case .insufficientSpace:
                "There isn’t enough space to copy Liquid. Free up space, then restore it from Speech model settings."
            case .incomplete:
                "Some Liquid model files couldn’t be reused. Check the model in Speech model settings."
            case .copyFailed:
                "Liquid couldn’t be copied from DictaFlow. Check the model in Speech model settings."
            }
        }
    }

    private let legacy: URL
    private let assets: [LiquidAsset]
    private let cloneFile: @Sendable (URL, URL) throws -> Bool
    private let requireSpace: @Sendable (Int64, URL) throws -> Void

    init(legacy: URL, assets: [LiquidAsset] = LiquidAssets.files,
         cloneFile: @escaping @Sendable (URL, URL) throws -> Bool = MigrationFiles.cloneFileIfSupported,
         requireSpace: @escaping @Sendable (Int64, URL) throws -> Void = MigrationFiles.requireSpace) {
        self.legacy = legacy
        self.assets = assets
        self.cloneFile = cloneFile
        self.requireSpace = requireSpace
    }

    private var modelPath: String { "Models/Liquid/\(LiquidAssets.revision)" }
    private static let stagedFilename = ".restore-copy.download"

    var hasLegacyFiles: Bool {
        guard (try? modelDirectoryExists(in: legacy)) == true else { return false }
        let source = legacy.appendingPathComponent(modelPath)
        return assets.contains { (try? MigrationFiles.attributes(source.appendingPathComponent($0.name))) != nil }
    }

    var canRestore: Bool {
        guard (try? modelDirectoryExists(in: legacy)) == true else { return false }
        let source = legacy.appendingPathComponent(modelPath)
        return assets.contains { asset in
            guard let attributes = try? MigrationFiles.attributes(source.appendingPathComponent(asset.name)) else { return false }
            return attributes[.type] as? FileAttributeType == .typeRegular
                && (attributes[.size] as? NSNumber)?.int64Value == asset.bytes
        }
    }

    @concurrent func restore(into root: URL) async throws {
        if let issue = try importModels(into: root, requireComplete: true) { throw issue }
    }

    func discardStagedCopy(in root: URL) throws {
        guard try modelDirectoryExists(in: root) else { return }
        let temporary = root.appendingPathComponent(modelPath).appendingPathComponent(Self.stagedFilename)
        guard let attributes = try MigrationFiles.attributes(temporary) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ApplicationSupportMigration.Failure.unsafeItem(temporary)
        }
        try FileManager.default.removeItem(at: temporary)
    }

    func importModels(into root: URL, requireComplete: Bool = false) throws -> Issue? {
        do {
            try discardStagedCopy(in: root)
            let sourceExists = try modelDirectoryExists(in: legacy)
            guard sourceExists || requireComplete else { return nil }
            let source = legacy.appendingPathComponent(modelPath)
            let target = root.appendingPathComponent(modelPath)
            let targetExists = try modelDirectoryExists(in: root)
            let temporary = target.appendingPathComponent(Self.stagedFilename)
            var existingCount = 0
            var assetsToCopy: [LiquidAsset] = []
            for asset in assets {
                try Task.checkCancellation()
                if targetExists, try LiquidAssets.verify(target.appendingPathComponent(asset.name), asset: asset) {
                    existingCount += 1
                } else if sourceExists, try LiquidAssets.verify(source.appendingPathComponent(asset.name), asset: asset) {
                    assetsToCopy.append(asset)
                }
            }
            if !assetsToCopy.isEmpty {
                try MigrationFiles.makePrivateDirectory(target)
                for asset in assetsToCopy {
                    try Task.checkCancellation()
                    try copy(asset, from: source, to: target, through: temporary)
                }
            }
            return existingCount + assetsToCopy.count == assets.count ? nil : .incomplete
        } catch is CancellationError {
            throw CancellationError()
        } catch ApplicationSupportMigration.Failure.insufficientSpace {
            return .insufficientSpace
        } catch let issue as Issue {
            return issue
        } catch {
            let failure = error as NSError
            if (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOSPC))
                || (failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteOutOfSpaceError) {
                return .insufficientSpace
            }
            return .copyFailed
        }
    }

    private func modelDirectoryExists(in root: URL) throws -> Bool {
        var directory = root
        for component in modelPath.split(separator: "/") {
            guard try MigrationFiles.attributes(directory) != nil else { return false }
            try MigrationFiles.requireDirectory(directory)
            directory.appendPathComponent(String(component))
        }
        guard try MigrationFiles.attributes(directory) != nil else { return false }
        try MigrationFiles.requireDirectory(directory)
        return true
    }

    private func copy(_ asset: LiquidAsset, from source: URL, to target: URL, through temporary: URL) throws {
        let files = FileManager.default
        let original = source.appendingPathComponent(asset.name)
        defer { try? files.removeItem(at: temporary) }
        if try !cloneFile(original, temporary) {
            try requireSpace(asset.bytes, target)
            try files.copyItem(at: original, to: temporary)
        }
        guard try LiquidAssets.verify(temporary, asset: asset) else { throw Issue.incomplete }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try MigrationFiles.syncFile(temporary)
        try Task.checkCancellation()
        let destination = target.appendingPathComponent(asset.name)
        guard rename(temporary.path, destination.path) == 0 else { throw MigrationFiles.posixError() }
        try MigrationFiles.syncDirectory(target)
    }
}

/// Locks serialize Omdo instances. Legacy apps and external hosts do not take these locks.
nonisolated final class OmdoMigrationLock: @unchecked Sendable {
    private let descriptor: Int32

    init(at url: URL) throws {
        try MigrationFiles.makePrivateDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_RDWR, 0o600)
        guard fd >= 0 else { throw MigrationFiles.posixError() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = MigrationFiles.posixError()
            close(fd)
            throw error
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

nonisolated enum MigrationFiles {
    static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    /// Try cloning before reserving space for the file's logical size.
    static func cloneFileIfSupported(_ source: URL, _ destination: URL) throws -> Bool {
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 { return true }
        let error = posixError()
        if error.code == .ENOTSUP || error.code == .EXDEV { return false }
        throw error
    }

    static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        let type: FileAttributeType
        switch mode_t(metadata.st_mode) & mode_t(S_IFMT) {
        case mode_t(S_IFREG): type = .typeRegular
        case mode_t(S_IFDIR): type = .typeDirectory
        case mode_t(S_IFLNK): type = .typeSymbolicLink
        default: type = .typeUnknown
        }
        let modification = metadata.st_mtimespec
        return [
            .type: type,
            .size: NSNumber(value: metadata.st_size),
            .systemFileNumber: NSNumber(value: metadata.st_ino),
            .systemNumber: NSNumber(value: metadata.st_dev),
            .modificationDate: Date(timeIntervalSince1970: Double(modification.tv_sec) + Double(modification.tv_nsec) / 1_000_000_000),
            .referenceCount: NSNumber(value: metadata.st_nlink),
            .ownerAccountID: NSNumber(value: metadata.st_uid),
            .posixPermissions: NSNumber(value: metadata.st_mode & 0o777)
        ]
    }

    static func requireDirectory(_ url: URL) throws {
        guard try attributes(url)?[.type] as? FileAttributeType == .typeDirectory else {
            throw ApplicationSupportMigration.Failure.unsafeItem(url)
        }
    }

    static func makePrivateDirectory(_ url: URL) throws {
        // Check each created ancestor before descending into it.
        if try attributes(url) == nil {
            let parent = url.deletingLastPathComponent()
            if try attributes(parent) == nil { try makePrivateDirectory(parent) }
            try requireDirectory(parent)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var folder = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    static func replaceDurably(_ data: Data, at url: URL, permissions: Int16 = 0o600) throws {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".omdo-\(UUID().uuidString)")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_CLOEXEC | O_WRONLY, mode_t(permissions))
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw posixError() }
        try syncDirectory(parent)
    }

    static func promote(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
        try syncDirectory(destination.deletingLastPathComponent())
    }

    static func syncFile(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    struct Fingerprint: Equatable, Codable {
        let inode: UInt64
        let device: UInt64
        let length: Int64
        let modified: Date
        let directory: Bool

        init(_ attributes: [FileAttributeKey: Any], at url: URL) throws {
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let length = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeDirectory || type == .typeRegular else {
                throw ApplicationSupportMigration.Failure.unsafeItem(url)
            }
            guard type != .typeRegular || (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw ApplicationSupportMigration.Failure.unsafeItem(url)
            }
            self.inode = inode.uint64Value
            self.device = device.uint64Value
            self.length = length.int64Value
            self.modified = modified
            directory = type == .typeDirectory
        }
    }

    static func snapshot(_ root: URL) throws -> [String: Fingerprint] {
        guard let attributes = try attributes(root) else { return [:] }
        let rootEntry = try Fingerprint(attributes, at: root)
        guard rootEntry.directory else { return ["": rootEntry] }
        var result = ["": rootEntry]
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for (path, entry) in try snapshot(child) {
                let name = child.lastPathComponent
                result[path.isEmpty ? name : name + "/" + path] = entry
            }
        }
        return result
    }

    static func syncTree(_ root: URL) throws {
        let items = try snapshot(root)
        for (relative, entry) in items.sorted(by: { $0.key.count > $1.key.count }) {
            let url = relative.isEmpty ? root : root.appendingPathComponent(relative)
            if entry.directory { try syncDirectory(url) }
            else { try syncFile(url) }
        }
    }

    static func requireSpace(_ bytes: Int64, at url: URL) throws {
        if let available = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, bytes > available {
            throw ApplicationSupportMigration.Failure.insufficientSpace
        }
    }
}

nonisolated struct ApplicationSupportMigration: Sendable {
    let paths: ApplicationSupportPaths
    private static let components = ["History", "Prompts", "AgentVoice"]
    private static let logger = Logger(subsystem: "com.dictaflow.storage", category: "Migration")

    enum Progress: Sendable, Equatable {
        case started(resuming: Bool)
        case copyingData
        case checkingSpeechModels
        case resumingSpeechModels
        case speechModelsIncomplete(LiquidModelMigration.Issue)
        case openingStores
    }

    enum Failure: LocalizedError {
        case legacyRunning, migrationInProgress, sourceChanged, insufficientSpace, unsafeItem(URL), destinationConflict(URL), missingCommittedData(URL),
             previousAttempt(URL), invalidLegacyDatabase(URL)

        var location: URL? {
            switch self {
            case .unsafeItem(let url), .destinationConflict(let url), .missingCommittedData(let url),
                 .previousAttempt(let url), .invalidLegacyDatabase(let url): url
            case .legacyRunning, .migrationInProgress, .sourceChanged, .insufficientSpace: nil
            }
        }

        var errorDescription: String? {
            switch self {
            case .legacyRunning: return "Quit the other copy of Omdo or DictaFlow, then try again."
            case .migrationInProgress: return "Another copy of Omdo is preparing local data. Close it, then try again."
            case .sourceChanged: return "DictaFlow data changed during the move. Quit the older app, then try again."
            case .insufficientSpace: return "There is not enough free disk space to copy your DictaFlow data."
            case .unsafeItem(let url): return "Omdo cannot safely read \(url.path). Check its type and permissions, then try again."
            case .destinationConflict(let url): return "Omdo found existing data at \(url.path). Keep both folders and resolve the conflict before retrying."
            case .invalidLegacyDatabase(let url):
                return "Omdo could not verify the database at \(url.path). Restore a working copy of that database, then try again."
            case .previousAttempt(let url): return "Move the saved copy at \(url.path) elsewhere before retrying the data migration."
            case .missingCommittedData(let url): return "Omdo’s migrated folder is missing at \(url.path). Restore that folder before retrying."
            }
        }
    }

    private struct Journal: Codable {
        enum Phase: String, Codable { case copying, staged, committed }
        var phase: Phase
        let stagingName: UUID
        var hasDestinationMarker: Bool?
        // Older journals used filesystem metadata to identify the destination.
        var destinationInode: UInt64?
        var destinationDevice: UInt64?
        var source: [String: [String: MigrationFiles.Fingerprint]]?
        var liquidImportPending: Bool?
    }

    struct Stores {
        let history: SQLiteHistoryStore
        let voice: Result<VoiceStore, any Error>
        var isNewStorage = false
    }

    /// Called before constructing app state, while no services can write to either root.
    @concurrent func prepare(report: @Sendable (Progress) async -> Void = { _ in },
                             liquidModels: LiquidModelMigration? = nil,
                             legacyIsRunning: @Sendable () -> Bool) async throws -> Stores {
        let files = FileManager.default
        let work = paths.storageWork
        try MigrationFiles.makePrivateDirectory(paths.migrationDirectory)
        let lock: OmdoMigrationLock
        do { lock = try OmdoMigrationLock(at: work.appendingPathComponent("storage.lock")) }
        catch let error as POSIXError where error.code == .EWOULDBLOCK { throw Failure.migrationInProgress }
        defer { withExtendedLifetime(lock) {} }
        let journalURL = work.appendingPathComponent("storage.json")
        let destination = paths.current
        let models = liquidModels ?? LiquidModelMigration(legacy: paths.legacy)
        let existing = try MigrationFiles.attributes(journalURL)
        if existing != nil, existing?[.type] as? FileAttributeType != .typeRegular {
            throw Failure.unsafeItem(journalURL)
        }
        var journal = try existing.map { _ in
            try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        }
        let hasIndependentDestination = try journal == nil && MigrationFiles.attributes(destination) != nil
        let isNewStorage = journal == nil && !hasIndependentDestination
        let reportsMigration: Bool
        if let journal { reportsMigration = journal.phase != .committed }
        else { reportsMigration = try hasLegacyData(includeModels: !hasIndependentDestination) }
        if reportsMigration {
            await report(.started(resuming: journal != nil))
        }
        guard !legacyIsRunning() else { throw Failure.legacyRunning }
        if var committed = journal, committed.phase == .committed {
            guard try MigrationFiles.attributes(destination) != nil else { throw Failure.missingCommittedData(destination) }
            guard try matchesDestination(destination, journal: committed) else { throw Failure.destinationConflict(destination) }
            let stores = reopenCommittedStores(at: destination)
            if committed.hasDestinationMarker != true {
                try markDestination(destination, journal: &committed)
                try save(committed, to: journalURL)
            }
            if committed.liquidImportPending == true {
                await report(.resumingSpeechModels)
                try await finishLiquidImport(models, journal: committed, at: journalURL, resuming: true, report: report)
            } else {
                discardAbandonedLiquidCopy(models)
            }
            return stores
        }

        let components = Self.components
        let source = try snapshotSource(includeDevFallback: !hasIndependentDestination)
        // A fully independent existing Omdo installation needs no data import.
        if hasIndependentDestination {
            guard source.values.allSatisfy(\.isEmpty) else { throw Failure.destinationConflict(destination) }
            try MigrationFiles.requireDirectory(destination)
            discardAbandonedLiquidCopy(models)
            return try await openStores(at: destination)
        }

        if let previous = journal, try MigrationFiles.attributes(destination) != nil {
            guard previous.phase == .staged, try matchesDestination(destination, journal: previous) else {
                throw Failure.destinationConflict(destination)
            }
            // A crash may have happened after promotion or during store validation.
            // Older journals included the optional model cache in their source snapshot.
            if previous.source?.filter({ $0.key != "Models/Liquid" }) != source {
                let saved = paths.uncommittedData
                guard try MigrationFiles.attributes(saved) == nil else { throw Failure.previousAttempt(saved) }
                // Preserve one interrupted copy in case it was modified outside Omdo.
                // It is offered in Finder alongside the original files.
                try MigrationFiles.promote(destination, to: saved)
                journal = nil
            }
        } else if let previous = journal {
            let stale = work.appendingPathComponent(previous.stagingName.uuidString)
            if try MigrationFiles.attributes(stale) != nil { try files.removeItem(at: stale) }
            journal = nil
        }

        if journal == nil {
            if reportsMigration { await report(.copyingData) }
            var pending = Journal(phase: .copying, stagingName: UUID(), source: source)
            try save(pending, to: journalURL)
            let staging = work.appendingPathComponent(pending.stagingName.uuidString, isDirectory: true)
            try MigrationFiles.makePrivateDirectory(staging)
            // Only this attempt owns this UUID. After promotion there is no staging
            // path, and the journal takes care of the promoted directory on retry.
            defer { try? files.removeItem(at: staging) }
            if try MigrationFiles.attributes(paths.legacy) != nil { try MigrationFiles.requireDirectory(paths.legacy) }
            let copiedBytes = source.values
                .flatMap(\.values).filter { !$0.directory }.reduce(Int64(0)) { $0 + $1.length }
            try MigrationFiles.requireSpace(copiedBytes, at: staging)
            for component in components {
                let origin = paths.legacy.appendingPathComponent(component)
                let target = staging.appendingPathComponent(component)
                guard let entries = source[component], !entries.isEmpty else { continue }
                guard entries[""]?.directory == true else { throw Failure.unsafeItem(origin) }
                try files.copyItem(at: origin, to: target)
                let copied = try MigrationFiles.snapshot(target)
                guard Set(copied.keys) == Set(entries.keys) else { throw Failure.sourceChanged }
                for (relative, entry) in entries {
                    let item = relative.isEmpty ? target : target.appendingPathComponent(relative)
                    try files.setAttributes([.posixPermissions: entry.directory ? 0o700 : 0o600], ofItemAtPath: item.path)
                    if !entry.directory {
                        let old = origin.appendingPathComponent(relative)
                        guard files.contentsEqual(atPath: old.path, andPath: item.path) else { throw Failure.sourceChanged }
                    }
                }
            }
            if source[Self.devFallbackComponent] != nil {
                try importLegacyDevPrompt(into: staging)
            }
            for relativePath in Self.storeDatabasePaths {
                do {
                    try normalizeDatabase(staging.appendingPathComponent(relativePath),
                                          legacyURL: paths.legacy.appendingPathComponent(relativePath))
                }
                catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
                    throw Failure.invalidLegacyDatabase(paths.legacy.appendingPathComponent(relativePath))
                }
            }
            try markDestination(staging, journal: &pending)
            try MigrationFiles.syncTree(staging)
            guard !legacyIsRunning(), try source == snapshotSource() else { throw Failure.sourceChanged }
            pending.phase = .staged
            try save(pending, to: journalURL)
            try MigrationFiles.promote(staging, to: destination)
            journal = pending
        }

        if reportsMigration { await report(.openingStores) }
        for relativePath in Self.storeDatabasePaths {
            let parts = relativePath.split(separator: "/", maxSplits: 1).map(String.init)
            if source[parts[0]]?[parts[1]] != nil {
                try Self.requireStoreDatabase(at: destination.appendingPathComponent(relativePath))
            }
        }
        var stores = try await openStores(at: destination)
        guard !legacyIsRunning(), try source == snapshotSource() else { throw Failure.sourceChanged }
        guard var committed = journal else { throw Failure.destinationConflict(destination) }
        if committed.hasDestinationMarker != true {
            try markDestination(destination, journal: &committed)
        }
        committed.phase = .committed
        committed.source = nil
        committed.liquidImportPending = reportsMigration && models.hasLegacyFiles ? true : nil
        try save(committed, to: journalURL)
        stores.isNewStorage = isNewStorage

        // Finish committing required data before using disk space for the optional model.
        if reportsMigration { await report(.checkingSpeechModels) }
        if committed.liquidImportPending == true {
            try await finishLiquidImport(models, journal: committed, at: journalURL, resuming: false, report: report)
        } else {
            discardAbandonedLiquidCopy(models)
        }
        return stores
    }

    private func finishLiquidImport(_ models: LiquidModelMigration, journal: Journal, at journalURL: URL,
                                    resuming: Bool, report: @Sendable (Progress) async -> Void) async throws {
        let issue = try models.importModels(into: paths.current, requireComplete: resuming)
        var settled = journal
        settled.liquidImportPending = nil
        do { try save(settled, to: journalURL) }
        catch {
            // The user data commit is already durable. A pending Liquid import can safely retry.
            Self.logger.error("Could not finish the Liquid migration journal: \(error.localizedDescription, privacy: .private)")
        }
        if let issue { await report(.speechModelsIncomplete(issue)) }
    }

    private func discardAbandonedLiquidCopy(_ models: LiquidModelMigration) {
        do { try models.discardStagedCopy(in: paths.current) }
        catch { Self.logger.error("Could not remove a staged Liquid copy: \(error.localizedDescription, privacy: .private)") }
    }

    private func hasLegacyData(includeModels: Bool) throws -> Bool {
        let legacy = paths.legacy
        guard try MigrationFiles.attributes(legacy) != nil else {
            return try MigrationFiles.attributes(paths.current) == nil && legacyDevPrompt() != nil
        }
        try MigrationFiles.requireDirectory(legacy)
        if try Self.components.contains(where: { try MigrationFiles.attributes(legacy.appendingPathComponent($0)) != nil })
            || (includeModels && (try? MigrationFiles.attributes(legacy.appendingPathComponent("Models/Liquid"))) != nil) {
            return true
        }
        return try MigrationFiles.attributes(paths.current) == nil && legacyDevPrompt() != nil
    }

    private static let devFallbackComponent = "Dev fallback prompt"

    private func snapshotSource(includeDevFallback: Bool = true) throws -> [String: [String: MigrationFiles.Fingerprint]] {
        if try MigrationFiles.attributes(paths.legacy) != nil { try MigrationFiles.requireDirectory(paths.legacy) }
        var source = try Dictionary(uniqueKeysWithValues: Self.components.map {
            ($0, try MigrationFiles.snapshot(paths.legacy.appendingPathComponent($0)))
        })
        if includeDevFallback, source["Prompts"]?["refinement.txt"] == nil, let fallback = try legacyDevPrompt() {
            source[Self.devFallbackComponent] = try MigrationFiles.snapshot(fallback)
        }
        return source
    }

    private func importLegacyDevPrompt(into staging: URL) throws {
        let prompt = staging.appendingPathComponent("Prompts/refinement.txt")
        guard try MigrationFiles.attributes(prompt) == nil, let legacy = try legacyDevPrompt() else { return }
        let data = try Data(contentsOf: legacy)
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try MigrationFiles.makePrivateDirectory(prompt.deletingLastPathComponent())
        try MigrationFiles.replaceDurably(data, at: prompt)
    }

    private func legacyDevPrompt() throws -> URL? {
        guard !paths.isRelease else { return nil }
        let legacy = paths.applicationSupport.appendingPathComponent("DictaFlow/Prompts/refinement.txt")
        for parent in [legacy.deletingLastPathComponent().deletingLastPathComponent(), legacy.deletingLastPathComponent()] {
            guard try MigrationFiles.attributes(parent) != nil else { return nil }
            try MigrationFiles.requireDirectory(parent)
        }
        guard let attributes = try MigrationFiles.attributes(legacy),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return legacy
    }

    private func markDestination(_ root: URL, journal: inout Journal) throws {
        let marker = root.appendingPathComponent(".omdo-storage-id")
        let expected = Data(journal.stagingName.uuidString.utf8)
        if let existing = try readMarker(marker) {
            guard existing == expected else { throw Failure.destinationConflict(root) }
        } else {
            try MigrationFiles.replaceDurably(expected, at: marker)
        }
        journal.hasDestinationMarker = true
        journal.destinationInode = nil
        journal.destinationDevice = nil
    }

    private func matchesDestination(_ url: URL, journal: Journal) throws -> Bool {
        try MigrationFiles.requireDirectory(url)
        if let marker = try readMarker(url.appendingPathComponent(".omdo-storage-id")) {
            return marker == Data(journal.stagingName.uuidString.utf8)
        }
        guard journal.hasDestinationMarker != true, let attributes = try MigrationFiles.attributes(url) else { return false }
        let identity = try MigrationFiles.Fingerprint(attributes, at: url)
        guard identity.inode == journal.destinationInode else { return false }
        // macOS can assign a different device number after reboot. For an
        // already committed legacy journal, reopen the same folder in place.
        return journal.phase == .committed || identity.device == journal.destinationDevice
    }

    private func readMarker(_ url: URL) throws -> Data? {
        guard let attributes = try MigrationFiles.attributes(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == 36 else {
            throw Failure.unsafeItem(url)
        }
        return try Data(contentsOf: url)
    }

    private func save(_ journal: Journal, to url: URL) throws {
        try MigrationFiles.replaceDurably(JSONEncoder().encode(journal), at: url)
    }

    /// The staged database and sidecars are a private clone. Let SQLite recover
    /// that clone and make a standalone backup before an app store opens it.
    private func normalizeDatabase(_ url: URL, legacyURL: URL) throws {
        guard let type = try MigrationFiles.attributes(url)?[.type] as? FileAttributeType else { return }
        guard type == .typeRegular else { throw Failure.unsafeItem(url) }
        let clean = url.deletingLastPathComponent().appendingPathComponent("migration-\(UUID().uuidString).sqlite")
        do {
            let original = try DatabaseQueue(path: url.path)
            let backup = try DatabaseQueue(path: clean.path)
            try original.backup(to: backup)
            let result = try backup.read { try String.fetchAll($0, sql: "PRAGMA quick_check") }
            guard result == ["ok"] else { throw Failure.invalidLegacyDatabase(legacyURL) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clean.path)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if try MigrationFiles.attributes(sidecar) != nil { try FileManager.default.removeItem(at: sidecar) }
        }
        guard rename(clean.path, url.path) == 0 else { throw MigrationFiles.posixError() }
    }

    private static let storeDatabasePaths = ["History/history.sqlite", "AgentVoice/voice.sqlite"]

    static func requireStoreDatabase(at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if try MigrationFiles.attributes(parent) != nil { try MigrationFiles.requireDirectory(parent) }
        guard try MigrationFiles.attributes(url)?[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.missingCommittedData(url)
        }
    }

    private func reopenCommittedStores(at root: URL) -> Stores {
        let history = SQLiteHistoryStore(root: root.appendingPathComponent("History"), requireExisting: true)
        let voiceURL = root.appendingPathComponent("AgentVoice/voice.sqlite")
        let voice = Result {
            try Self.requireStoreDatabase(at: voiceURL)
            return try VoiceStore(url: voiceURL)
        }
        return Stores(history: history, voice: voice)
    }

    private func openStores(at root: URL) async throws -> Stores {
        let voiceURL = root.appendingPathComponent("AgentVoice/voice.sqlite")
        let historyRoot = root.appendingPathComponent("History")
        for directory in [historyRoot, voiceURL.deletingLastPathComponent()] {
            if try MigrationFiles.attributes(directory) != nil { try MigrationFiles.requireDirectory(directory) }
        }
        let history = SQLiteHistoryStore(root: historyRoot)
        try await history.validateStorage()
        let voice = try VoiceStore(url: voiceURL)
        return Stores(history: history, voice: .success(voice))
    }
}
