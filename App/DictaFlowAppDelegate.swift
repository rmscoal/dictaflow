import AppKit
import Combine
import SwiftUI

@MainActor
final class DictaFlowAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    @Published private(set) var appState: DictaFlowAppState?
    @Published private(set) var migration: MigrationWindowState? {
        didSet { updateMigrationCloseButton() }
    }
    @Published private(set) var modelMigrationNotice: String?
    private let paths = ApplicationSupportPaths.current
    private let appearanceService: AppAppearanceApplying = SystemAppAppearanceService()
    private var appearanceSubscription: AnyCancellable?
    private var mainWindowCoordinator: MainWindowCoordinator?
    private var launchTask: Task<Void, Never>?
    private var migrationWindow: NSWindow?
    // Keep using the exact stores validated and committed before Continue.
    private var preparedStores: ApplicationSupportMigration.Stores?
    private let recordingOverlayCoordinator = RecordingOverlayCoordinator()

    var legacyDataLocations: [URL] { paths.legacyArtifacts() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareApplication()
    }

    func prepareApplication() {
        guard launchTask == nil, appState == nil, preparedStores == nil else { return }
        // Hosted tests construct their stores with fixture URLs.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if migration != nil {
            migration = MigrationWindowState()
        }
        appearanceService.apply(UserDefaultsSettingsStore().appAppearance)
        launchTask = Task {
            defer { launchTask = nil }
            do {
                let bundleID = paths.bundleID
                let stores = try await ApplicationSupportMigration(paths: paths).prepare(report: { [weak self] progress in
                    await self?.reportMigration(progress)
                }) {
                    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                        .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
                }
                if paths.isRelease {
                    do {
                        try await WhisperModelDownloadService.seedOmdoModels(paths: paths) { [weak self] in
                            await self?.showModelCopyStep(forNewStorage: stores.isNewStorage)
                        }
                    }
                    catch { modelMigrationNotice = "Some local models could not be copied. Omdo will retry the copy at the next launch." }
                }
                if migration?.stage != nil {
                    preparedStores = stores
                    migration?.isComplete = true
                } else {
                    finishLaunching(stores: stores, fromMigration: false)
                }
            } catch {
                let shouldPresent = migration == nil
                var state = migration ?? MigrationWindowState()
                state.error = error.localizedDescription
                if let location = (error as? ApplicationSupportMigration.Failure)?.location {
                    state.revealLocation = FileManager.default.fileExists(atPath: location.path)
                        ? location : location.deletingLastPathComponent()
                }
                migration = state
                if shouldPresent { showMigrationWindow() }
            }
        }
    }

    private func reportMigration(_ progress: ApplicationSupportMigration.Progress) {
        switch progress {
        case .started(let resuming):
            let shouldPresent = migration?.stage == nil && migrationWindow == nil
            migration = MigrationWindowState(stage: .preparing, resuming: resuming)
            if shouldPresent { showMigrationWindow() }
        case .copyingData: advanceMigration(to: .copyingData)
        case .checkingSpeechModels: advanceMigration(to: .checkingSpeechModels)
        case .speechModelsIncomplete: migration?.speechModelsIncomplete = true
        case .openingStores: advanceMigration(to: .openingStores)
        }
    }

    private func advanceMigration(to stage: MigrationWindowState.Stage) {
        guard migration?.stage != nil else { return }
        migration?.stage = stage
    }

    private func showModelCopyStep(forNewStorage: Bool) {
        if migration?.stage != nil {
            migration?.stage = .copyingOfflineModels
        } else if forNewStorage {
            migration = MigrationWindowState(stage: .copyingOfflineModels, copiesOnlyOfflineModels: true)
            if migrationWindow == nil { showMigrationWindow() }
        }
    }

    func showMigrationWindow() {
        guard migration != nil else { return }
        if migrationWindow == nil {
            let controller = NSHostingController(rootView: MigrationWindowView(delegate: self))
            let window = NSWindow(contentViewController: controller)
            window.title = "Omdo"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask = [.titled, .closable]
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = AppTheme.windowBackgroundColor
            window.delegate = self
            window.center()
            migrationWindow = window
        }
        updateMigrationCloseButton()
        NSApp.setActivationPolicy(.regular)
        migrationWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateMigrationCloseButton() {
        migrationWindow?.standardWindowButton(.closeButton)?.isEnabled = migration?.canClose == true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        migration?.canClose == true
    }

    func windowWillClose(_ notification: Notification) {
        if appState == nil { NSApp.setActivationPolicy(.accessory) }
    }

    func continueAfterMigration() {
        guard let stores = preparedStores else { return }
        finishLaunching(stores: stores, fromMigration: true)
    }

    private func finishLaunching(stores: ApplicationSupportMigration.Stores, fromMigration: Bool) {
        migrationWindow?.close()
        migrationWindow = nil
        migration = nil
        preparedStores = nil
        let state = DictaFlowAppState(paths: paths, stores: stores)
        let window = MainWindowCoordinator(appState: state)
        mainWindowCoordinator = window
        appearanceSubscription = state.$appAppearance
            .removeDuplicates()
            .sink { [weak self] appearance in self?.appearanceService.apply(appearance) }
        state.attach(mainWindowRouter: window)
        state.attach(recordingOverlayRouter: recordingOverlayCoordinator)
        appState = state
        state.handleApplicationLaunch(showMainWindowAfterUpgrade: fromMigration)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if appState == nil { showMigrationWindow() }
            else { appState?.showMainWindow() }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        appState.prepareForTermination()
        Task {
            await appState.waitForRefinementShutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
