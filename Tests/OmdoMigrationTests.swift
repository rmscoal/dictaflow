import AgentVoice
import GRDB
import os
import XCTest
@testable import DictaFlow_Dev

final class OmdoMigrationTests: XCTestCase {
    private actor ProgressLog {
        var values: [ApplicationSupportMigration.Progress] = []
        func append(_ value: ApplicationSupportMigration.Progress) { values.append(value) }
    }

    private actor CopyAttempts {
        var count = 0
        func record() { count += 1 }
    }

    private let legacyHelper = "/Applications/DictaFlow Dev.app/Contents/MacOS/dictaflow-mcp"
    private let currentHelper = "/Applications/Omdo Dev.app/Contents/MacOS/dictaflow-mcp"
    private let installation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testStorageKeepsLegacyDataAndNeverFallsBackAfterCommit() async throws {
        let support = try fixture()
        let paths = ApplicationSupportPaths(applicationSupport: support, bundleID: "com.dictaflow.dev")
        let prompt = paths.legacy.appendingPathComponent("Prompts/refinement.txt")
        let recording = paths.legacy.appendingPathComponent("History/Recordings/fixture.m4a")
        let shared = paths.legacySharedModels.appendingPathComponent("whisper-fixture")
        for item in [prompt, recording, shared] {
            try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("legacy fixture".utf8).write(to: item)
        }
        let migration = ApplicationSupportMigration(paths: paths)
        _ = try await migration.prepare { false }
        let newPrompt = paths.current.appendingPathComponent("Prompts/refinement.txt")
        XCTAssertEqual(try Data(contentsOf: newPrompt), try Data(contentsOf: prompt))
        XCTAssertEqual(try Data(contentsOf: paths.current.appendingPathComponent("History/Recordings/fixture.m4a")),
                       try Data(contentsOf: recording))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.current.appendingPathComponent("History/history.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.current.appendingPathComponent("AgentVoice/voice.sqlite").path))
        XCTAssertEqual(paths.sharedModels, paths.legacySharedModels)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        try Data("old app later wrote here".utf8).write(to: prompt)
        _ = try await migration.prepare { false }
        XCTAssertEqual(try String(contentsOf: newPrompt, encoding: .utf8), "legacy fixture")
    }

    func testHasCompletedMigrationTracksJournalPhase() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        XCTAssertFalse(ApplicationSupportMigration.hasCompletedMigration(paths: paths))
        _ = try await ApplicationSupportMigration(paths: paths).prepare { false }
        XCTAssertTrue(ApplicationSupportMigration.hasCompletedMigration(paths: paths))
        // The journal itself is never reported as a legacy artifact.
        XCTAssertFalse(paths.legacyArtifacts().contains(paths.storageWork.appendingPathComponent("storage.json")))
    }

    func testCleanAndCommittedLaunchesDoNotReportMigrationProgress() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let migration = ApplicationSupportMigration(paths: paths)
        let progress = ProgressLog()
        let clean = try await migration.prepare(report: { await progress.append($0) }) { false }
        XCTAssertTrue(clean.isNewStorage)

        try FileManager.default.createDirectory(at: paths.legacy.appendingPathComponent("Prompts"), withIntermediateDirectories: true)
        let reopened = try await migration.prepare(report: { await progress.append($0) }) { false }
        XCTAssertFalse(reopened.isNewStorage)
        let events = await progress.values
        XCTAssertTrue(events.isEmpty)
    }

    func testCommittedStoreFailuresStayLocalAndDoNotCreateReplacementDatabases() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let migration = ApplicationSupportMigration(paths: paths)
        _ = try await migration.prepare { false }

        let historyURL = paths.current.appendingPathComponent("History/history.sqlite")
        let voiceURL = paths.current.appendingPathComponent("AgentVoice/voice.sqlite")
        let corrupt = Data(repeating: 0x61, count: 4096)
        try corrupt.write(to: voiceURL, options: .atomic)
        do {
            let withCorruptVoice = try await migration.prepare { false }
            XCTAssertThrowsError(try withCorruptVoice.voice.get())
            try await withCorruptVoice.history.validateStorage()
            XCTAssertEqual(try Data(contentsOf: voiceURL), corrupt)
        }

        try FileManager.default.removeItem(at: historyURL)
        try FileManager.default.removeItem(at: voiceURL)
        let withMissingStores = try await migration.prepare { false }
        XCTAssertThrowsError(try withMissingStores.voice.get())
        do {
            try await withMissingStores.history.validateStorage()
            XCTFail("Expected the missing history database to be reported")
        } catch ApplicationSupportMigration.Failure.missingCommittedData(let url) {
            XCTAssertEqual(url, historyURL)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: voiceURL.path))
    }

    func testStagedResumeRejectsMissingImportedHistory() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        do {
            let history = SQLiteHistoryStore(root: paths.legacy.appendingPathComponent("History"))
            try await history.validateStorage()
        }
        let migration = ApplicationSupportMigration(paths: paths)
        let checks = OSAllocatedUnfairLock(initialState: 0)
        do {
            _ = try await migration.prepare { checks.withLock { count in count += 1; return count == 3 } }
            XCTFail("Expected an interruption after promotion")
        } catch ApplicationSupportMigration.Failure.sourceChanged {}

        let imported = paths.current.appendingPathComponent("History/history.sqlite")
        try FileManager.default.removeItem(at: imported)
        do {
            _ = try await migration.prepare { false }
            XCTFail("Expected a missing imported database to prevent commit")
        } catch ApplicationSupportMigration.Failure.missingCommittedData(let url) {
            XCTAssertEqual(url, imported)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
    }

    func testStagedResumeReimportsChangedDevFallbackPrompt() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let relative = "Prompts/refinement.txt"
        let fallback = paths.applicationSupport.appendingPathComponent("DictaFlow/\(relative)")
        try FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("initial".utf8).write(to: fallback)
        let migration = ApplicationSupportMigration(paths: paths)
        let changed = OSAllocatedUnfairLock(initialState: false)
        do {
            _ = try await migration.prepare(report: { progress in
                guard progress == .openingStores else { return }
                let result: Void? = try? Data("changed fallback".utf8).write(to: fallback, options: .atomic)
                changed.withLock { $0 = result != nil }
            }) { false }
            XCTFail("Expected the changed fallback to prevent commit")
        } catch ApplicationSupportMigration.Failure.sourceChanged {}
        XCTAssertTrue(changed.withLock { $0 })

        _ = try await migration.prepare { false }
        XCTAssertEqual(try String(contentsOf: paths.current.appendingPathComponent(relative), encoding: .utf8), "changed fallback")
        XCTAssertEqual(try String(contentsOf: paths.uncommittedData.appendingPathComponent(relative), encoding: .utf8), "initial")
    }

    func testUpgradeReportsStagesAndIncompleteSpeechModels() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let assetDirectory = paths.legacy.appendingPathComponent("Models/Liquid/\(LiquidAssets.revision)")
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        try Data("invalid model".utf8).write(to: assetDirectory.appendingPathComponent(LiquidAssets.files[0].name))
        let progress = ProgressLog()
        _ = try await ApplicationSupportMigration(paths: paths).prepare(report: { await progress.append($0) }) { false }
        let events = await progress.values
        XCTAssertEqual(events, [.started(resuming: false), .copyingData, .openingStores, .checkingSpeechModels, .speechModelsIncomplete(.incomplete)])
    }

    func testLiquidMigrationClonesOnAPFSBeforeCheckingCopySpace() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow")
        let volume = try paths.applicationSupport.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
        try XCTSkipUnless(volume.volumeSupportsFileCloning == true, "This fixture requires file cloning support.")
        let modelPath = "Models/Liquid/\(LiquidAssets.revision)/fixture.gguf"
        let source = paths.legacy.appendingPathComponent(modelPath)
        let destination = paths.current.appendingPathComponent(modelPath)
        let modelData = Data("abc".utf8)
        let asset = LiquidAsset(name: "fixture.gguf", bytes: 3,
                                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try modelData.write(to: source)

        let models = LiquidModelMigration(legacy: paths.legacy, assets: [asset]) { _, _ in
            XCTFail("A clone must not be gated by the physical-copy space check.")
            throw ApplicationSupportMigration.Failure.insufficientSpace
        }
        _ = try await ApplicationSupportMigration(paths: paths).prepare(liquidModels: models) { false }

        let keys: Set<URLResourceKey> = [.fileContentIdentifierKey]
        let sourceContent = try XCTUnwrap(source.resourceValues(forKeys: keys).fileContentIdentifier)
        let destinationContent = try XCTUnwrap(destination.resourceValues(forKeys: keys).fileContentIdentifier)
        XCTAssertEqual(sourceContent, destinationContent)
        let sourceInode = try XCTUnwrap(MigrationFiles.attributes(source)?[.systemFileNumber] as? NSNumber)
        let destinationInode = try XCTUnwrap(MigrationFiles.attributes(destination)?[.systemFileNumber] as? NSNumber)
        XCTAssertNotEqual(sourceInode, destinationInode)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("xyz".utf8))
        XCTAssertEqual(try Data(contentsOf: source), modelData)
        XCTAssertEqual(try Data(contentsOf: destination), Data("xyz".utf8))
    }

    func testLiquidSpaceFailureCommitsUserDataAndModelCanBeRestoredLater() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow")
        let modelPath = "Models/Liquid/\(LiquidAssets.revision)/fixture.gguf"
        let source = paths.legacy.appendingPathComponent(modelPath)
        let destination = paths.current.appendingPathComponent(modelPath)
        let prompt = paths.legacy.appendingPathComponent("Prompts/refinement.txt")
        let modelData = Data("abc".utf8)
        let asset = LiquidAsset(name: "fixture.gguf", bytes: 3,
                                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for file in [source, prompt] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try modelData.write(to: source)
        try Data("keep my prompt".utf8).write(to: prompt)

        let progress = ProgressLog()
        let lowDisk = LiquidModelMigration(legacy: paths.legacy, assets: [asset], cloneFile: { _, _ in false }) { _, _ in
            throw ApplicationSupportMigration.Failure.insufficientSpace
        }
        let migration = ApplicationSupportMigration(paths: paths)
        _ = try await migration.prepare(report: { await progress.append($0) }, liquidModels: lowDisk) { false }
        let events = await progress.values
        XCTAssertEqual(events, [.started(resuming: false), .copyingData, .openingStores, .checkingSpeechModels,
                                .speechModelsIncomplete(.insufficientSpace)])
        XCTAssertEqual(try Data(contentsOf: paths.current.appendingPathComponent("Prompts/refinement.txt")), Data("keep my prompt".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let partial = destination.deletingLastPathComponent().appendingPathComponent(".restore-copy.download")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("interrupted copy".utf8).write(to: partial)
        let nextLaunch = ProgressLog()
        _ = try await migration.prepare(report: { await nextLaunch.append($0) }, liquidModels: lowDisk) { false }
        let eventsAfterCommit = await nextLaunch.values
        XCTAssertTrue(eventsAfterCommit.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let restored = LiquidModelMigration(legacy: paths.legacy, assets: [asset], cloneFile: { _, _ in false })
        XCTAssertTrue(restored.canRestore)
        try await restored.restore(into: paths.current)
        try await lowDisk.restore(into: paths.current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: destination), modelData)
        XCTAssertEqual(try Data(contentsOf: source), modelData)
    }

    func testInterruptedLiquidImportResumesOrDefersWithoutRecopyingUserData() async throws {
        for enoughSpace in [true, false] {
            let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow")
            let modelDirectory = "Models/Liquid/\(LiquidAssets.revision)"
            let asset = LiquidAsset(name: "fixture.gguf", bytes: 3,
                                    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            let source = paths.legacy.appendingPathComponent(modelDirectory).appendingPathComponent(asset.name)
            let target = paths.current.appendingPathComponent(modelDirectory)
            let originalPrompt = paths.legacy.appendingPathComponent("Prompts/refinement.txt")
            let copiedPrompt = paths.current.appendingPathComponent("Prompts/refinement.txt")
            for file in [source, originalPrompt] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try Data("abc".utf8).write(to: source)
            try Data("original".utf8).write(to: originalPrompt)
            let migration = ApplicationSupportMigration(paths: paths)
            let interrupted = LiquidModelMigration(legacy: paths.legacy, assets: [asset],
                                                   cloneFile: { _, _ in throw CancellationError() })
            do {
                _ = try await migration.prepare(liquidModels: interrupted) { false }
                XCTFail("Expected an interruption during the Liquid import.")
            } catch is CancellationError {}

            XCTAssertEqual(try Data(contentsOf: copiedPrompt), Data("original".utf8))
            try Data("edited after commit".utf8).write(to: copiedPrompt)
            let partial = target.appendingPathComponent(".restore-copy.download")
            try Data("partial copy".utf8).write(to: partial)
            let retry = LiquidModelMigration(legacy: paths.legacy, assets: [asset], cloneFile: { _, _ in false }) { _, _ in
                XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
                if !enoughSpace { throw ApplicationSupportMigration.Failure.insufficientSpace }
            }
            let progress = ProgressLog()
            _ = try await migration.prepare(report: { await progress.append($0) }, liquidModels: retry) { false }
            let events = await progress.values
            XCTAssertEqual(events, enoughSpace ? [.resumingSpeechModels]
                                               : [.resumingSpeechModels, .speechModelsIncomplete(.insufficientSpace)])
            XCTAssertEqual(try Data(contentsOf: copiedPrompt), Data("edited after commit".utf8))
            XCTAssertEqual(try Data(contentsOf: source), Data("abc".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: target.appendingPathComponent(asset.name).path), enoughSpace)
            let routineLaunch = ProgressLog()
            _ = try await migration.prepare(report: { await routineLaunch.append($0) }, liquidModels: retry) { false }
            let routineEvents = await routineLaunch.values
            XCTAssertTrue(routineEvents.isEmpty)
        }
    }

    func testPromptOnlyUpgradeDoesNotResumeLiquidAfterInterruption() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow")
        let prompt = paths.legacy.appendingPathComponent("Prompts/refinement.txt")
        try FileManager.default.createDirectory(at: prompt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy prompt".utf8).write(to: prompt)
        let journalURL = paths.storageWork.appendingPathComponent("storage.json")
        let journalAtModelCheck = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let migration = ApplicationSupportMigration(paths: paths)
        _ = try await migration.prepare(report: { progress in
            guard progress == .checkingSpeechModels else { return }
            let journal = try? Data(contentsOf: journalURL)
            journalAtModelCheck.withLock { $0 = journal }
        }) { false }

        // Relaunch with the journal that was on disk before the model step returned.
        let interruptedJournal = try XCTUnwrap(journalAtModelCheck.withLock { $0 })
        try interruptedJournal.write(to: journalURL, options: .atomic)
        let progress = ProgressLog()
        _ = try await migration.prepare(report: { await progress.append($0) }) { false }
        let relaunchEvents = await progress.values
        XCTAssertTrue(relaunchEvents.isEmpty)
        XCTAssertEqual(try Data(contentsOf: paths.current.appendingPathComponent("Prompts/refinement.txt")), Data("legacy prompt".utf8))
    }

    func testPendingLiquidImportChecksDestinationWhenLegacyDirectoryDisappears() async throws {
        for hasVerifiedDestination in [false, true] {
            let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow")
            let modelDirectory = "Models/Liquid/\(LiquidAssets.revision)"
            let asset = LiquidAsset(name: "fixture.gguf", bytes: 3,
                                    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            let source = paths.legacy.appendingPathComponent(modelDirectory)
            let destination = paths.current.appendingPathComponent(modelDirectory)
            let retainedSource = paths.legacy.appendingPathComponent("Saved Liquid")
            let data = Data("abc".utf8)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try data.write(to: source.appendingPathComponent(asset.name))
            let progress = ProgressLog()
            let models = LiquidModelMigration(legacy: paths.legacy, assets: [asset])

            _ = try await ApplicationSupportMigration(paths: paths).prepare(report: { event in
                await progress.append(event)
                guard event == .checkingSpeechModels else { return }
                do {
                    if hasVerifiedDestination {
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                        try data.write(to: destination.appendingPathComponent(asset.name))
                    }
                    try FileManager.default.moveItem(at: source, to: retainedSource)
                } catch {
                    XCTFail("Couldn’t arrange the missing source fixture: \(error)")
                }
            }, liquidModels: models) { false }

            let events = await progress.values
            XCTAssertEqual(events.contains(.speechModelsIncomplete(.incomplete)), !hasVerifiedDestination)
            XCTAssertEqual(try Data(contentsOf: retainedSource.appendingPathComponent(asset.name)), data)
        }
    }

    func testStorageSpaceCheckIgnoresUnusedLiquidRevision() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let unused = paths.legacy.appendingPathComponent("Models/Liquid/old-revision/unused.gguf")
        try FileManager.default.createDirectory(at: unused.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: unused)
        let volume = try paths.applicationSupport.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let capacity = try XCTUnwrap(volume.volumeAvailableCapacityForImportantUsage)
        do {
            let handle = try FileHandle(forWritingTo: unused)
            defer { try? handle.close() }
            // Use a sparse file so this fixture reserves no model-sized storage.
            try handle.truncate(atOffset: UInt64(capacity) + 1_073_741_824)
        }
        let prompt = paths.legacy.appendingPathComponent("Prompts/refinement.txt")
        try FileManager.default.createDirectory(at: prompt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep this prompt".utf8).write(to: prompt)
        _ = try await ApplicationSupportMigration(paths: paths).prepare { false }
        XCTAssertEqual(try Data(contentsOf: paths.current.appendingPathComponent("Prompts/refinement.txt")),
                       try Data(contentsOf: prompt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.appendingPathComponent("Models/Liquid").path))
    }

    func testDatabaseQuickCheckReportsTheRetainedLegacyPath() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let legacy = paths.legacy.appendingPathComponent("History/history.sqlite")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let db = try DatabaseQueue(path: legacy.path)
            try await db.writeWithoutTransaction {
                try $0.execute(sql: "CREATE TABLE fixture (value INTEGER CHECK (value > 0))")
                try $0.execute(sql: "PRAGMA ignore_check_constraints = ON")
                try $0.execute(sql: "INSERT INTO fixture VALUES (-1)")
            }
        }
        do {
            _ = try await ApplicationSupportMigration(paths: paths).prepare { false }
            XCTFail("Expected quick_check to detect the invalid row")
        } catch ApplicationSupportMigration.Failure.invalidLegacyDatabase(let url) {
            XCTAssertEqual(url, legacy)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.path))
    }

    func testInterruptedUpgradeReportsResumeAndWaitsForLegacyApp() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        try FileManager.default.createDirectory(at: paths.storageWork, withIntermediateDirectories: true)
        let journal = paths.storageWork.appendingPathComponent("storage.json")
        try JSONEncoder().encode(["phase": "copying", "stagingName": UUID().uuidString]).write(to: journal)
        let progress = ProgressLog()
        let migration = ApplicationSupportMigration(paths: paths)
        do {
            _ = try await migration.prepare(report: { await progress.append($0) }) { true }
            XCTFail("Expected the active DictaFlow process to block migration")
        } catch ApplicationSupportMigration.Failure.legacyRunning {}
        let blockedEvents = await progress.values
        XCTAssertEqual(blockedEvents, [.started(resuming: true)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.path))

        _ = try await migration.prepare(report: { await progress.append($0) }) { false }
        let allEvents = await progress.values
        XCTAssertEqual(allEvents, [.started(resuming: true), .started(resuming: true), .copyingData, .openingStores, .checkingSpeechModels])
    }

    func testConcurrentMigrationReportsAnActionableFailure() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let lock = try OmdoMigrationLock(at: paths.storageWork.appendingPathComponent("storage.lock"))
        defer { withExtendedLifetime(lock) {} }
        do {
            _ = try await ApplicationSupportMigration(paths: paths).prepare { false }
            XCTFail("Expected an active migration to hold the lock")
        } catch ApplicationSupportMigration.Failure.migrationInProgress {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.path))
    }

    @MainActor
    func testMigrationWindowCanCloseOnlyAfterWorkSettles() {
        var state = MigrationWindowState(stage: .copyingData)
        XCTAssertFalse(state.canClose)
        state.error = "Test failure"
        XCTAssertTrue(state.canClose)
        state.error = nil
        state.isComplete = true
        XCTAssertTrue(state.canClose)
    }

    func testCommittedLegacyJournalRecoversAfterDeviceNumberChanges() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let migration = ApplicationSupportMigration(paths: paths)
        _ = try await migration.prepare { false }

        let journalURL = paths.storageWork.appendingPathComponent("storage.json")
        let marker = paths.current.appendingPathComponent(".omdo-storage-id")
        let expectedMarker = try Data(contentsOf: marker)
        try FileManager.default.removeItem(at: marker)
        var legacyJournal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        let attributes = try XCTUnwrap(MigrationFiles.attributes(paths.current))
        let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
        let device = try XCTUnwrap(attributes[.systemNumber] as? NSNumber)
        legacyJournal.removeValue(forKey: "hasDestinationMarker")
        legacyJournal["destinationInode"] = inode
        legacyJournal["destinationDevice"] = device.uint64Value ^ 1
        try JSONSerialization.data(withJSONObject: legacyJournal).write(to: journalURL)

        _ = try await migration.prepare { false }
        XCTAssertEqual(try Data(contentsOf: marker), expectedMarker)
        let upgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        XCTAssertEqual(upgraded["phase"] as? String, "committed")
        XCTAssertEqual(upgraded["hasDestinationMarker"] as? Bool, true)
    }

    func testCommittedMarkerAcceptsRestoredCopyAndRejectsUnmarkedFolder() async throws {
        let files = FileManager.default
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let migration = ApplicationSupportMigration(paths: paths)
        _ = try await migration.prepare { false }
        let backup = paths.applicationSupport.appendingPathComponent("Fixture backup")
        try files.moveItem(at: paths.current, to: backup)
        try files.createDirectory(at: paths.current, withIntermediateDirectories: false)
        do {
            _ = try await migration.prepare { false }
            XCTFail("Expected an unmarked replacement to be rejected")
        } catch ApplicationSupportMigration.Failure.destinationConflict {}
        XCTAssertTrue(try files.contentsOfDirectory(atPath: paths.current.path).isEmpty)

        try files.removeItem(at: paths.current)
        try files.copyItem(at: backup, to: paths.current)
        _ = try await migration.prepare { false }
    }

    func testStorageDefersActiveLegacyAppAndPreservesConflictingRoots() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow")
        let migration = ApplicationSupportMigration(paths: paths)
        do {
            _ = try await migration.prepare { true }
            XCTFail("Expected migration to wait for the older app")
        } catch ApplicationSupportMigration.Failure.legacyRunning {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.path))
        for root in [paths.legacy, paths.current] {
            let prompts = root.appendingPathComponent("Prompts")
            try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
            try Data(root.lastPathComponent.utf8).write(to: prompts.appendingPathComponent("refinement.txt"))
        }
        do {
            _ = try await migration.prepare { false }
            XCTFail("Expected a conflict")
        } catch ApplicationSupportMigration.Failure.destinationConflict {}
        for root in [paths.legacy, paths.current] {
            let prompt = root.appendingPathComponent("Prompts/refinement.txt")
            XCTAssertEqual(try String(contentsOf: prompt, encoding: .utf8), root.lastPathComponent)
        }
    }

    func testSymlinkedHostAndPrivateStorageItemsAreRejected() async throws {
        let root = try fixture()
        let target = root.appendingPathComponent("dotfile")
        let settings = root.appendingPathComponent("settings.json")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        XCTAssertThrowsError(try AgentVoiceHostMigration.read(settings))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")

        let paths = ApplicationSupportPaths(applicationSupport: root, bundleID: "com.dictaflow.dev")
        try FileManager.default.createDirectory(at: paths.legacy, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.legacy.appendingPathComponent("Prompts"),
                                                    withDestinationURL: root)
        do {
            _ = try await ApplicationSupportMigration(paths: paths).prepare { false }
            XCTFail("Expected migration to reject a symlinked private data folder")
        } catch ApplicationSupportMigration.Failure.unsafeItem {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.path))
    }

    func testInterruptedStorageAttemptKeepsAtMostOneSavedCopy() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let prompt = paths.legacy.appendingPathComponent("Prompts/refinement.txt")
        try FileManager.default.createDirectory(at: prompt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("initial".utf8).write(to: prompt)
        let migration = ApplicationSupportMigration(paths: paths)

        func interruptAfterPromotion() async throws {
            let calls = OSAllocatedUnfairLock(initialState: 0)
            do {
                _ = try await migration.prepare {
                    calls.withLock { count in count += 1; return count == 3 }
                }
                XCTFail("Expected source to become active before commit")
            } catch ApplicationSupportMigration.Failure.sourceChanged {}
        }

        try await interruptAfterPromotion()
        try Data("second".utf8).write(to: prompt)
        try await interruptAfterPromotion()
        try Data("third".utf8).write(to: prompt)
        do {
            _ = try await migration.prepare { false }
            XCTFail("Expected existing recovery copy to be preserved")
        } catch ApplicationSupportMigration.Failure.previousAttempt(let saved) {
            XCTAssertEqual(saved, paths.uncommittedData)
        }
        let suffix = "Prompts/refinement.txt"
        XCTAssertEqual(try String(contentsOf: paths.uncommittedData.appendingPathComponent(suffix), encoding: .utf8), "initial")
        XCTAssertEqual(try String(contentsOf: paths.current.appendingPathComponent(suffix), encoding: .utf8), "second")
        XCTAssertEqual(try String(contentsOf: prompt, encoding: .utf8), "third")
    }

    func testSharedModelImportRetriesMissingOrCorruptLegacyCache() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow")
        let marker = paths.migrationDirectory.appendingPathComponent("Shared Models/complete")
        let attempts = CopyAttempts()
        try await WhisperModelDownloadService.seedOmdoModels(paths: paths) { await attempts.record() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.createDirectory(at: paths.legacySharedModels, withIntermediateDirectories: true)
        try Data().write(to: paths.legacySharedModels.appendingPathComponent("unrecognized-model.bin"))
        try await WhisperModelDownloadService.seedOmdoModels(paths: paths) { await attempts.record() }
        let beforeCandidate = await attempts.count
        XCTAssertEqual(beforeCandidate, 0)
        let model = try XCTUnwrap(WhisperModelDescriptor.allCases.first)
        let source = paths.legacySharedModels.appendingPathComponent(model.filename)
        try Data("invalid model".utf8).write(to: source)
        do {
            try await WhisperModelDownloadService.seedOmdoModels(paths: paths) { await attempts.record() }
            XCTFail("Expected the copy to report the bad checksum")
        } catch ModelDownloadServiceError.checksumMismatch {}
        let withCandidate = await attempts.count
        XCTAssertEqual(withCandidate, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sharedModels.appendingPathComponent(model.filename).path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "invalid model")
    }

    func testSharedModelRetryDoesNotRestoreRemovedEncoder() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow")
        let model = try XCTUnwrap(WhisperModelDescriptor.allCases.first)
        let refinement = try XCTUnwrap(RefinementModelDescriptor.storedModels.first)
        let encoder = paths.legacySharedModels.appendingPathComponent(model.encoderDirectoryName)
        try FileManager.default.createDirectory(at: encoder, withIntermediateDirectories: true)
        let encoderFile = encoder.appendingPathComponent("model.mil")
        let encoderData = Data("encoder".utf8)
        try encoderData.write(to: encoderFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: encoderFile.path)
        let corrupt = paths.legacySharedModels.appendingPathComponent(refinement.filename)
        try Data("bad cache".utf8).write(to: corrupt)
        try FileManager.default.createDirectory(at: paths.sharedModels, withIntermediateDirectories: true)
        try Data("existing model".utf8).write(to: paths.sharedModels.appendingPathComponent(model.filename))
        do {
            try await WhisperModelDownloadService.seedOmdoModels(paths: paths)
            XCTFail("Expected the corrupt refinement model to require a retry")
        } catch ModelDownloadServiceError.checksumMismatch {}
        let imported = paths.sharedModels.appendingPathComponent(model.encoderDirectoryName)
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent("model.mil")), encoderData)
        try FileManager.default.removeItem(at: imported)
        try FileManager.default.removeItem(at: corrupt)
        try await WhisperModelDownloadService.seedOmdoModels(paths: paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.path))
    }

    func testCodexInlineHooksReferencingEitherAliasRequireManualMigration() throws {
        let hooks = """
        [[hooks.Stop]]
        hooks = [
            { type = "mcp_tool", server = 'SERVER', tool = "on_stop" },
        ]
        """
        let registration = """

        [mcp_servers.dictaflow]
        command = "\(legacyHelper)"
        args = []
        """
        for alias in ["dictaflow", "omdo"] {
            let source = hooks.replacingOccurrences(of: "SERVER", with: alias) + registration
            let config = try CodexMCPConfiguration(Data(source.utf8))
            XCTAssertThrowsError(try config.candidate(executable: currentHelper, arguments: [], ownsPath: { _ in true })) {
                guard case AgentVoiceHostMigration.Failure.unownedHook = $0 else { return XCTFail("Expected manual migration") }
            }
        }
        let unrelated = hooks.replacingOccurrences(of: "SERVER", with: "other")
        let config = try CodexMCPConfiguration(Data((unrelated + registration).utf8))
        let migrated = try config.candidate(executable: currentHelper, arguments: [], ownsPath: { _ in true })
        XCTAssertTrue(String(decoding: migrated, as: UTF8.self).hasPrefix(unrelated))
    }

    func testCodexRekeysBothTableAndDottedNamespacesWithoutLosingPolicy() throws {
        let args = AgentVoiceHostInstaller.serverArguments(appID: "com.dictaflow.dev", installationID: installation, host: .codex)
        let array = args.map { "\"\($0)\"" }.joined(separator: ", ")
        let originals = [
            """
            # dictaflow remains in the comment
            mcp_servers.dictaflow.command = '\(legacyHelper)'
            mcp_servers.dictaflow.args = [\(array)]
            mcp_servers.dictaflow.enabled = false
            mcp_servers.dictaflow.tools.prepare_spoken_response.approval_mode = "prompt"
            model = 'keep'
            """,
            """
            model = 'keep'
            [mcp_servers."dictaflow"]
            command = '\(legacyHelper)'
            args = [\(array)]
            enabled = false
            [mcp_servers.dictaflow.tools.prepare_spoken_response]
            approval_mode = "prompt"
            [mcp_servers.unrelated]
            command = "dictaflow is part of this value"
            """
        ]
        for original in originals {
            let configuration = try CodexMCPConfiguration(Data(original.utf8))
            let migrated = try configuration.candidate(executable: currentHelper, arguments: args, ownsPath: { $0 == legacyHelper })
            let result = try CodexMCPConfiguration(migrated)
            XCTAssertFalse(result.aliases.contains("dictaflow"))
            XCTAssertTrue(result.aliases.contains("omdo"))
            XCTAssertTrue(result.isDisabled(alias: "omdo"))
            let output = String(decoding: migrated, as: UTF8.self)
            XCTAssertTrue(output.contains("approval_mode = \"prompt\""))
            XCTAssertTrue(output.contains("model = 'keep'"))
            XCTAssertTrue(output.contains(currentHelper))
            if original.contains("unrelated") {
                XCTAssertTrue(output.hasSuffix("[mcp_servers.unrelated]\ncommand = \"dictaflow is part of this value\""))
            }
        }
    }

    func testCodexSetupCutoverThroughInstalledCLI() async throws {
        guard let cli = ProcessInfo.processInfo.environment["OMDO_TEST_CODEX"] else {
            throw XCTSkip("Set OMDO_TEST_CODEX to test real Codex readback.")
        }
        let host = try fixture()
        let helper = host.appendingPathComponent("dictaflow-mcp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let args = AgentVoiceHostInstaller.serverArguments(appID: "com.dictaflow.dev", installationID: installation, host: .codex)
        let array = args.map { "\"\($0)\"" }.joined(separator: ", ")
        let configURL = AgentVoiceHostInstaller.codexConfigURL(homeDirectoryURL: host)
        let hooksURL = AgentVoiceHostInstaller.codexHooksURL(homeDirectoryURL: host)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        model = "keep-this-setting"
        [mcp_servers.dictaflow]
        command = '\(legacyHelper)'
        args = [\(array)]
        enabled = false
        default_tools_approval_mode = "prompt"
        [mcp_servers.dictaflow.tools.prepare_spoken_response]
        approval_mode = "approve"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        var hooks: [String: Any] = [:]
        for event in AgentVoiceHostInstaller.expectedHookEvents(for: .codex) {
            var hook = try XCTUnwrap(AgentVoiceHostInstaller.expectedHookHandler(for: .codex, event: event))
            hook["server"] = "dictaflow"
            hook.removeValue(forKey: "statusMessage")
            hooks[event] = [["hooks": [hook]]]
        }
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: hooksURL)
        let completion = try await AgentVoiceHostInstaller.setUp(
            host: .codex, executable: helper.path, appID: "com.dictaflow.dev", installationID: installation,
            agentVoiceEnabled: true, homeDirectoryURL: host, cliDiscovery: { _ in cli }, hostIdle: { true })
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(completion.contains("remains disabled"))
        XCTAssertTrue(contents.contains("[mcp_servers.omdo.tools.prepare_spoken_response]"))
        XCTAssertTrue(contents.contains("default_tools_approval_mode = \"prompt\""))
        XCTAssertTrue(contents.hasPrefix("model = \"keep-this-setting\""))
        XCTAssertFalse(contents.contains("[mcp_servers.dictaflow"))
        XCTAssertTrue(AgentVoiceHostInstaller.hooksStatus(data: try Data(contentsOf: hooksURL),
                                                         host: .codex, executable: helper.path).matches)
    }

    func testCodexSetupFallsBackToCLIForInlineLegacyEntry() async throws {
        let host = try fixture()
        let cli = host.appendingPathComponent("fake-codex")
        let script = #"""
        #!/usr/bin/env python3
        import json, os, re, sys
        args = sys.argv[1:]
        if args == ["--version"]:
            print("codex-cli 0.171.0"); raise SystemExit(0)
        home = os.environ["CODEX_HOME"]
        path = os.path.join(home, "config.toml")
        def read():
            try: return open(path).read()
            except FileNotFoundError: return ""
        def entry(name):
            for line in read().splitlines():
                if line.strip().startswith("mcp_servers") and not line.strip().startswith("["):
                    im = re.search(re.escape(name) + r'\s*=\s*\{([^}]*)\}', line)
                    if im:
                        body = im.group(1)
                        icmd = re.search(r'command\s*=\s*(?:\'([^\']*)\'|"((?:[^"\\]|\\.)*)")', body)
                        iarg = re.search(r'args\s*=\s*\[(.*?)\]', body, re.S)
                        ien = re.search(r'enabled\s*=\s*(true|false)', body)
                        cmdv = (icmd.group(1) if icmd.group(1) is not None else json.loads('"' + icmd.group(2) + '"')) if icmd else ""
                        argv = []
                        if iarg:
                            for sq, dq in re.findall(r"'([^']*)'|\"((?:[^\"\\]|\\.)*)\"", iarg.group(1)):
                                argv.append(sq if sq else json.loads('"' + dq + '"'))
                        return {"transport": {"command": cmdv, "args": argv}, "enabled": (ien.group(1) == "true") if ien else True}
            m = re.search(r'\[mcp_servers\.' + re.escape(name) + r'\]\n(.*?)(?=\n\[|\Z)', read(), re.S)
            if not m: return None
            body = m.group(1)
            cmd = re.search(r'command\s*=\s*"((?:[^"\\]|\\.)*)"', body)
            argm = re.search(r'args\s*=\s*\[(.*?)\]', body, re.S)
            en = re.search(r'enabled\s*=\s*(true|false)', body)
            return {"transport": {"command": json.loads('"' + cmd.group(1) + '"') if cmd else "", "args": [json.loads('"' + x + '"') for x in re.findall(r'"((?:[^"\\]|\\.)*)"', argm.group(1))] if argm else []}, "enabled": (en.group(1) == "true") if en else True}
        if args[:2] == ["mcp", "list"]:
            print("omdo"); raise SystemExit(0)
        if args[:2] == ["mcp", "get"]:
            found = entry(args[-1])
            if found is None: raise SystemExit(1)
            print(json.dumps(found)); raise SystemExit(0)
        if args[:2] == ["mcp", "remove"]:
            name = args[-1]; out = []; skip = False
            for line in read().splitlines(True):
                stripped = line.strip()
                if stripped.startswith("mcp_servers") and not stripped.startswith("[") and "=" in stripped and (" " + name + " ") in (" " + stripped + " "):
                    continue
                hdr = re.match(r'\[(.+)\]\s*$', stripped)
                if hdr:
                    parts = hdr.group(1).split(".")
                    skip = len(parts) >= 2 and parts[0] == "mcp_servers" and parts[1].strip('"') == name
                if skip: continue
                out.append(line)
            open(path, "w").write("".join(out)); raise SystemExit(0)
        raise SystemExit(1)
        """#
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let helper = host.appendingPathComponent("dictaflow-mcp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let configURL = AgentVoiceHostInstaller.codexConfigURL(homeDirectoryURL: host)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        model = "keep-this-setting"
        mcp_servers = { dictaflow = { command = '/Applications/DictaFlow.app/Contents/MacOS/dictaflow-mcp', args = ['--app-id', 'com.dictaflow', '--installation-id', 'stale', '--host', 'codex'] } }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let completion = try await AgentVoiceHostInstaller.setUp(
            host: .codex, executable: helper.path, appID: "com.dictaflow.dev", installationID: installation,
            agentVoiceEnabled: true, homeDirectoryURL: host, cliDiscovery: { _ in cli.path }, hostIdle: { true })
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(completion.contains("configured"))
        XCTAssertTrue(contents.contains("model = \"keep-this-setting\""))
        XCTAssertTrue(contents.contains("[mcp_servers.omdo]"))
        XCTAssertFalse(contents.contains("dictaflow = {"))
        let configuration = try CodexMCPConfiguration(Data(contents.utf8))
        XCTAssertFalse(configuration.aliases.contains("dictaflow"))
        XCTAssertTrue(configuration.aliases.contains("omdo"))
    }

    /// Fake Codex CLI that reads and removes both section and inline
    /// `mcp_servers` entries, preserving unrelated inline entries on removal.
    private func fakeCodexCLI(in host: URL) throws -> URL {
        let cli = host.appendingPathComponent("fake-codex")
        let script = #"""
        #!/usr/bin/env python3
        import json, os, re, sys
        args = sys.argv[1:]
        if args == ["--version"]:
            print("codex-cli 0.171.0"); raise SystemExit(0)
        home = os.environ["CODEX_HOME"]
        path = os.path.join(home, "config.toml")
        def read():
            try: return open(path).read()
            except FileNotFoundError: return ""
        def quoted(body, key):
            m = re.search(key + r'\s*=\s*(?:\'([^\']*)\'|"((?:[^"\\]|\\.)*)")', body)
            if not m: return ""
            return m.group(1) if m.group(1) is not None else json.loads('"' + m.group(2) + '"')
        def parse_body(body):
            argv = []
            am = re.search(r'args\s*=\s*\[(.*?)\]', body, re.S)
            if am:
                for sq, dq in re.findall(r"'([^']*)'|\"((?:[^\"\\]|\\.)*)\"", am.group(1)):
                    argv.append(sq if sq else json.loads('"' + dq + '"'))
            en = re.search(r'enabled\s*=\s*(true|false)', body)
            return {"transport": {"command": quoted(body, "command"), "args": argv}, "enabled": (en.group(1) == "true") if en else True}
        def entry(name):
            for line in read().splitlines():
                if line.strip().startswith("mcp_servers") and not line.strip().startswith("["):
                    m = re.search(re.escape(name) + r'\s*=\s*\{([^}]*)\}', line)
                    if m: return parse_body(m.group(1))
            m = re.search(r'\[mcp_servers\.' + re.escape(name) + r'\]\n(.*?)(?=\n\[|\Z)', read(), re.S)
            return parse_body(m.group(1)) if m else None
        if args[:2] == ["mcp", "list"]:
            print("omdo"); raise SystemExit(0)
        if args[:2] == ["mcp", "get"]:
            found = entry(args[-1])
            if found is None: raise SystemExit(1)
            print(json.dumps(found)); raise SystemExit(0)
        if args[:2] == ["mcp", "remove"]:
            name = args[-1]; out = []; skip = False
            for line in read().splitlines(True):
                stripped = line.strip()
                if stripped.startswith("mcp_servers") and not stripped.startswith("[") and "=" in stripped:
                    m = re.search(re.escape(name) + r'\s*=\s*\{[^}]*\}', line)
                    if m:
                        start, end = m.span()
                        if end < len(line) and line[end] == ",":
                            end += 1
                            while end < len(line) and line[end] == " ": end += 1
                        elif start > 0 and "," in line[:start]:
                            start = line.rfind(",", 0, start)
                        line = line[:start] + line[end:]
                        if re.search(r'mcp_servers\s*=\s*\{\s*\}', line): continue
                    out.append(line); continue
                hdr = re.match(r'\[(.+)\]\s*$', stripped)
                if hdr:
                    parts = hdr.group(1).split(".")
                    skip = len(parts) >= 2 and parts[0] == "mcp_servers" and parts[1].strip('"') == name
                if skip: continue
                out.append(line)
            open(path, "w").write("".join(out)); raise SystemExit(0)
        raise SystemExit(1)
        """#
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }

    private func fakeCodexFixture(config: String) throws -> (host: URL, cli: URL, helper: URL, configURL: URL) {
        let host = try fixture()
        let cli = try fakeCodexCLI(in: host)
        let helper = host.appendingPathComponent("dictaflow-mcp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let configURL = AgentVoiceHostInstaller.codexConfigURL(homeDirectoryURL: host)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        return (host, cli, helper, configURL)
    }

    func testCodexSetupFallbackPreservesUnrelatedInlineServer() async throws {
        let other = "other = { command = '/usr/bin/other', args = ['keep'] }"
        let fixture = try fakeCodexFixture(config: """
        model = "keep-this-setting"
        mcp_servers = { dictaflow = { command = '/Applications/DictaFlow.app/Contents/MacOS/dictaflow-mcp', args = ['--app-id', 'com.dictaflow', '--installation-id', 'stale', '--host', 'codex'], enabled = false }, \(other) }
        """)
        let completion = try await AgentVoiceHostInstaller.setUp(
            host: .codex, executable: fixture.helper.path, appID: "com.dictaflow.dev", installationID: installation,
            agentVoiceEnabled: true, homeDirectoryURL: fixture.host, cliDiscovery: { _ in fixture.cli.path }, hostIdle: { true })
        let contents = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(completion.contains("remains disabled"), completion)
        XCTAssertTrue(contents.contains(other), contents)
        XCTAssertFalse(contents.contains("dictaflow = {"), contents)
        let configuration = try CodexMCPConfiguration(Data(contents.utf8))
        XCTAssertEqual(configuration.aliases, ["omdo", "other"])
        XCTAssertTrue(configuration.isDisabled(alias: "omdo"))
    }

    func testCodexSetupFallbackRejectsForeignInlineEntryMentioningOwnedHelper() async throws {
        let config = """
        # previous helper lived at /Applications/DictaFlow.app/Contents/MacOS/dictaflow-mcp
        mcp_servers = { dictaflow = { command = '/usr/bin/foreign', args = ['x'] } }
        """
        let fixture = try fakeCodexFixture(config: config)
        do {
            _ = try await AgentVoiceHostInstaller.setUp(
                host: .codex, executable: fixture.helper.path, appID: "com.dictaflow.dev", installationID: installation,
                agentVoiceEnabled: true, homeDirectoryURL: fixture.host, cliDiscovery: { _ in fixture.cli.path }, hostIdle: { true })
            XCTFail("A foreign entry must not be removed on a file-wide text match")
        } catch CodexMCPConfiguration.EditError.unknownOwner {}
        XCTAssertEqual(try String(contentsOf: fixture.configURL, encoding: .utf8), config)
    }

    func testCodexSetupFallbackPreservesBothAliasesOnCollision() async throws {
        let config = """
        mcp_servers = { dictaflow = { command = '/Applications/DictaFlow.app/Contents/MacOS/dictaflow-mcp', args = ['a'] }, omdo = { command = '/Applications/Omdo.app/Contents/MacOS/dictaflow-mcp', args = ['b'] } }
        """
        let fixture = try fakeCodexFixture(config: config)
        do {
            _ = try await AgentVoiceHostInstaller.setUp(
                host: .codex, executable: fixture.helper.path, appID: "com.dictaflow.dev", installationID: installation,
                agentVoiceEnabled: true, homeDirectoryURL: fixture.host, cliDiscovery: { _ in fixture.cli.path }, hostIdle: { true })
            XCTFail("Both aliases together must require manual resolution")
        } catch CodexMCPConfiguration.EditError.collision {}
        XCTAssertEqual(try String(contentsOf: fixture.configURL, encoding: .utf8), config)
    }

    func testCodexInlineUnrelatedServersSurviveCandidate() throws {
        let other = "other = { command = '/usr/bin/other', args = ['keep'] }"
        let original = Data("model = \"keep\"\nmcp_servers = { \(other) }\n".utf8)
        let migrated = try CodexMCPConfiguration(original).candidate(
            executable: currentHelper, arguments: ["ours"], ownsPath: { _ in false })
        let output = String(decoding: migrated, as: UTF8.self)
        XCTAssertTrue(output.contains(other), output)
        let result = try CodexMCPConfiguration(migrated)
        XCTAssertEqual(result.aliases, ["omdo", "other"])
        // A managed alias inside an inline table stays strictly unsupported
        // for editing, so setup falls back to the CLI for it.
        for alias in ["dictaflow", "omdo"] {
            let inline = try CodexMCPConfiguration(Data("mcp_servers = { \(alias) = {} }".utf8))
            XCTAssertThrowsError(try inline.candidate(executable: currentHelper, arguments: ["ours"], ownsPath: { _ in true })) {
                guard case CodexMCPConfiguration.EditError.unsupported = $0 else { return XCTFail("Expected unsupported") }
            }
        }
    }

    func testCodexAdoptsLegacyEntryWithDriftedArgsAcrossAppRename() throws {
        let oldArgs = AgentVoiceHostInstaller.serverArguments(
            appID: "com.dictaflow.dev", installationID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, host: .codex)
        let newArgs = AgentVoiceHostInstaller.serverArguments(appID: "com.dictaflow", installationID: installation, host: .codex)
        let array = oldArgs.map { "\"\($0)\"" }.joined(separator: ", ")
        let original = Data("""
        [mcp_servers.dictaflow]
        command = '\(legacyHelper)'
        args = [\(array)]
        enabled = false
        """.utf8)
        let owns: (String) -> Bool = {
            AgentVoiceHostMigration.isOwnedHelper($0, current: "/Applications/Omdo.app/Contents/MacOS/dictaflow-mcp", appID: "com.dictaflow")
        }
        let migrated = try CodexMCPConfiguration(original).candidate(
            executable: "/Applications/Omdo.app/Contents/MacOS/dictaflow-mcp", arguments: newArgs, ownsPath: owns)
        let result = try CodexMCPConfiguration(migrated)
        XCTAssertFalse(result.aliases.contains("dictaflow"))
        XCTAssertTrue(result.aliases.contains("omdo"))
        XCTAssertTrue(result.isDisabled(alias: "omdo"))
        let output = String(decoding: migrated, as: UTF8.self)
        XCTAssertTrue(output.contains("/Applications/Omdo.app/Contents/MacOS/dictaflow-mcp"))
        XCTAssertTrue(output.contains(installation.uuidString))
        XCTAssertFalse(output.contains("22222222-2222-2222-2222-222222222222"))
    }

    func testCodexStillRejectsForeignHelperEvenWithLegacyAlias() throws {
        let original = Data("""
        [mcp_servers.dictaflow]
        command = "/Applications/Other.app/Contents/MacOS/dictaflow-mcp"
        args = ['stale']
        """.utf8)
        let owns: (String) -> Bool = {
            AgentVoiceHostMigration.isOwnedHelper($0, current: "/Applications/Omdo Dev.app/Contents/MacOS/dictaflow-mcp", appID: "com.dictaflow.dev")
        }
        XCTAssertThrowsError(try CodexMCPConfiguration(original).candidate(
            executable: "/Applications/Omdo Dev.app/Contents/MacOS/dictaflow-mcp", arguments: ["ours"], ownsPath: owns)) {
            guard case CodexMCPConfiguration.EditError.unknownOwner = $0 else { return XCTFail("Expected unknown owner") }
        }
    }

    func testMuseAdoptsLegacyEntryWithDriftedArgs() throws {
        let oldArgs = AgentVoiceHostInstaller.serverArguments(
            appID: "com.dictaflow", installationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, host: .museCode)
        let newArgs = AgentVoiceHostInstaller.serverArguments(appID: "com.dictaflow", installationID: installation, host: .museCode)
        let releaseHelper = "/Applications/DictaFlow.app/Contents/MacOS/dictaflow-mcp"
        let currentReleaseHelper = "/Applications/Omdo.app/Contents/MacOS/dictaflow-mcp"
        let old: [String: Any] = ["mcp_servers": [
            "dictaflow": ["transport": "stdio", "command": releaseHelper, "args": oldArgs, "enabled": false]]]
        let original = try JSONSerialization.data(withJSONObject: old)
        let owns: (String) -> Bool = {
            AgentVoiceHostMigration.isOwnedHelper($0, current: currentReleaseHelper, appID: "com.dictaflow")
        }
        let updated = try AgentVoiceHostInstaller.migratedMuseSettings(original, path: "/fixture",
            executable: currentReleaseHelper, arguments: newArgs, ownsPath: owns)
        let state = AgentVoiceHostInstaller.museEntryStatus(data: updated, executable: currentReleaseHelper, arguments: newArgs)
        XCTAssertTrue(state.matches)
        XCTAssertTrue(state.disabled)
    }

    func testCodexProtectsForeignAndUnsupportedEntries() throws {
        let original = Data("[mcp_servers.dictaflow]\ncommand = '/foreign'\nargs = ['foreign']\n".utf8)
        let parsed = try CodexMCPConfiguration(original)
        XCTAssertThrowsError(try parsed.candidate(executable: currentHelper, arguments: ["ours"], ownsPath: { _ in false }))
        let inline = try CodexMCPConfiguration(Data("mcp_servers = { dictaflow = {} }".utf8))
        XCTAssertThrowsError(try inline.candidate(executable: currentHelper, arguments: ["ours"], ownsPath: { _ in true })) {
            guard case CodexMCPConfiguration.EditError.unsupported = $0 else { return XCTFail("Expected unsupported") }
        }
    }

    func testMuseMovesRegistrationAndGuardTogetherAndPreservesDisabledFlag() throws {
        let args = AgentVoiceHostInstaller.serverArguments(appID: "com.dictaflow.dev", installationID: installation, host: .museCode)
        let old: [String: Any] = [
            "mcp_servers": [
                "dictaflow": ["transport": "stdio", "command": legacyHelper, "args": args, "enabled": false],
                "other": ["command": "unchanged"]
            ],
            "hooks": ["PreToolUse": [["matcher": "mcp__dictaflow__.*", "hooks": [
                ["type": "command", "command": AgentVoiceHostInstaller.museGuardCommand(executable: legacyHelper), "timeout": 5]
            ]]]]
        ]
        let original = try JSONSerialization.data(withJSONObject: old)
        let updated = try AgentVoiceHostInstaller.migratedMuseSettings(original, path: "/fixture",
            executable: currentHelper, arguments: args, ownsPath: { $0 == legacyHelper })
        let state = AgentVoiceHostInstaller.museEntryStatus(data: updated, executable: currentHelper, arguments: args)
        XCTAssertTrue(state.matches)
        XCTAssertTrue(state.disabled)
        XCTAssertTrue(AgentVoiceHostInstaller.hooksStatus(data: updated, host: .museCode, executable: currentHelper).matches)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let servers = try XCTUnwrap(root["mcp_servers"] as? [String: [String: Any]])
        XCTAssertNil(servers["dictaflow"])
        XCTAssertEqual(servers["other"]?["command"] as? String, "unchanged")
        // Drifted args are adopted and rewritten, not treated as foreign.
        let rewritten = try AgentVoiceHostInstaller.migratedMuseSettings(original,
            path: "/fixture", executable: currentHelper, arguments: ["different installation"], ownsPath: { $0 == legacyHelper })
        XCTAssertTrue(AgentVoiceHostInstaller.museEntryStatus(
            data: rewritten, executable: currentHelper, arguments: ["different installation"]).matches)
        XCTAssertThrowsError(try AgentVoiceHostInstaller.migratedMuseSettings(original,
            path: "/fixture", executable: currentHelper, arguments: args, ownsPath: { _ in false }))
    }

    func testHostRecoveryFinalizesAnAlreadyAppliedPairWithoutRewritingIt() async throws {
        let root = try fixture()
        let config = root.appendingPathComponent("config.toml")
        let hooks = root.appendingPathComponent("hooks.json")
        let migration = AgentVoiceHostMigration(host: .codex, configuration: config, hooks: hooks, applicationSupport: root)
        let changes = [
            try AgentVoiceHostMigration.change(at: config, original: nil, candidate: Data("new registry".utf8)),
            try AgentVoiceHostMigration.change(at: hooks, original: nil, candidate: Data("new hooks".utf8)),
        ]
        var checks = 0
        do {
            try await migration.apply(executable: currentHelper, arguments: [], prepare: { changes }, verify: { _, _ in }) {
                checks += 1
                if checks >= 3 { throw AgentVoiceHostMigration.Failure.hostRunning("Codex") }
            }
            XCTFail("Expected the pending journal to survive the interruption")
        } catch AgentVoiceHostMigration.Failure.interrupted {}

        // Simulate the files left by a run that reached cleanup.
        try changes[1].candidate.write(to: hooks)
        checks = 0
        try await migration.apply(executable: currentHelper, arguments: [], prepare: {
            XCTFail("Expected the existing journal to be reused")
            return []
        }, verify: { _, _ in }) {
            checks += 1
            if checks > 1 { throw AgentVoiceHostMigration.Failure.hostRunning("Codex") }
        }
        XCTAssertFalse(migration.hasPendingUpdate)
        XCTAssertEqual(try AgentVoiceHostMigration.read(config), changes[0].candidate)
        XCTAssertEqual(try AgentVoiceHostMigration.read(hooks), changes[1].candidate)
    }

    func testHostUpdateResumesAfterLossOfQuiescenceBetweenFiles() async throws {
        let root = try fixture()
        let config = root.appendingPathComponent("config.toml")
        let hooks = root.appendingPathComponent("hooks.json")
        let migration = AgentVoiceHostMigration(host: .codex, configuration: config, hooks: hooks,
                                                applicationSupport: root)
        let changes = [
            try AgentVoiceHostMigration.change(at: config, original: nil, candidate: Data("new registry".utf8)),
            try AgentVoiceHostMigration.change(at: hooks, original: nil, candidate: Data("new hooks".utf8))
        ]
        var checks = 0
        do {
            try await migration.apply(executable: currentHelper, arguments: [], prepare: { changes }, verify: { _, _ in }) {
                checks += 1
                if checks >= 3 { throw AgentVoiceHostMigration.Failure.hostRunning("Codex") }
            }
            XCTFail("Expected recovery to be required")
        } catch AgentVoiceHostMigration.Failure.interrupted(let cause, let recoveryError) {
            guard case AgentVoiceHostMigration.Failure.hostRunning = cause,
                  case AgentVoiceHostMigration.Failure.hostRunning = recoveryError else {
                return XCTFail("Expected both the apply and rollback errors")
            }
        }
        XCTAssertTrue(migration.hasPendingUpdate)
        XCTAssertEqual(try AgentVoiceHostMigration.read(config), changes[0].candidate)
        XCTAssertNil(try AgentVoiceHostMigration.read(hooks))
        try await migration.apply(executable: currentHelper, arguments: [], prepare: {
            XCTFail("Recovery must use the recorded intent")
            return []
        }, verify: { _, _ in }, checkIdle: {})
        XCTAssertFalse(migration.hasPendingUpdate)
        XCTAssertEqual(try AgentVoiceHostMigration.read(hooks), changes[1].candidate)
    }
}
