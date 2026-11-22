import AgentVoice
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

    func testUpgradeReportsStagesAndIncompleteSpeechModels() async throws {
        let paths = ApplicationSupportPaths(applicationSupport: try fixture(), bundleID: "com.dictaflow.dev")
        let assetDirectory = paths.legacy.appendingPathComponent("Models/Liquid/\(LiquidAssets.revision)")
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        try Data("invalid model".utf8).write(to: assetDirectory.appendingPathComponent(LiquidAssets.files[0].name))
        let progress = ProgressLog()
        _ = try await ApplicationSupportMigration(paths: paths).prepare(report: { await progress.append($0) }) { false }
        let events = await progress.values
        XCTAssertEqual(events, [.started(resuming: false), .copyingData, .checkingSpeechModels, .speechModelsIncomplete, .openingStores])
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
        XCTAssertEqual(allEvents, [.started(resuming: true), .started(resuming: true), .copyingData, .checkingSpeechModels, .openingStores])
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

    func testCodexProtectsForeignAndUnsupportedEntries() throws {
        let original = Data("[mcp_servers.dictaflow]\ncommand = '/foreign'\nargs = ['foreign']\n".utf8)
        let parsed = try CodexMCPConfiguration(original)
        XCTAssertThrowsError(try parsed.candidate(executable: currentHelper, arguments: ["ours"], ownsPath: { _ in false }))
        XCTAssertThrowsError(try CodexMCPConfiguration(Data("mcp_servers = { dictaflow = {} }".utf8)))
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
        XCTAssertThrowsError(try AgentVoiceHostInstaller.migratedMuseSettings(original,
            path: "/fixture", executable: currentHelper, arguments: ["different installation"], ownsPath: { _ in true }))
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
        } catch AgentVoiceHostMigration.Failure.interrupted {}
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
