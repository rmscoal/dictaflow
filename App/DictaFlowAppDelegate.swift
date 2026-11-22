import AppKit
import Combine

@MainActor
final class DictaFlowAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var appState: DictaFlowAppState?
    @Published private(set) var launchError: String?
    @Published private(set) var modelMigrationNotice: String?
    private let paths = ApplicationSupportPaths.current
    private let appearanceService: AppAppearanceApplying = SystemAppAppearanceService()
    private var appearanceSubscription: AnyCancellable?
    private var mainWindowCoordinator: MainWindowCoordinator?
    private var launchTask: Task<Void, Never>?
    private let recordingOverlayCoordinator = RecordingOverlayCoordinator()

    var legacyDataLocations: [URL] { paths.legacyArtifacts() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareApplication()
    }

    func prepareApplication() {
        guard launchTask == nil, appState == nil else { return }
        // Hosted tests construct their stores with fixture URLs.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        launchError = nil
        launchTask = Task {
            defer { launchTask = nil }
            do {
                let bundleID = paths.bundleID
                let stores = try await ApplicationSupportMigration(paths: paths).prepare {
                    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                        .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
                }
                if paths.isRelease {
                    do { try await WhisperModelDownloadService.seedOmdoModels(paths: paths) }
                    catch { modelMigrationNotice = "Some local models could not be copied. Omdo will retry the copy at the next launch." }
                }
                let state = DictaFlowAppState(paths: paths, stores: stores)
                await state.agentVoice?.waitForInitialModelCheck()
                finishLaunching(with: state)
            } catch {
                launchError = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Omdo could not open its local data"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func finishLaunching(with state: DictaFlowAppState) {
        let window = MainWindowCoordinator(appState: state)
        mainWindowCoordinator = window
        appearanceSubscription = state.$appAppearance
            .removeDuplicates()
            .sink { [weak self] appearance in self?.appearanceService.apply(appearance) }
        state.attach(mainWindowRouter: window)
        state.attach(recordingOverlayRouter: recordingOverlayCoordinator)
        appState = state
        state.handleApplicationLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { appState?.showMainWindow() }
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
