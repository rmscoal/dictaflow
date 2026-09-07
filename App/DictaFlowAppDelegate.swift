import AppKit
import Combine

@MainActor
final class DictaFlowAppDelegate: NSObject, NSApplicationDelegate {
    let appState = DictaFlowAppState()
    private let appearanceService: AppAppearanceApplying = SystemAppAppearanceService()
    private var appearanceSubscription: AnyCancellable?
    private lazy var mainWindowCoordinator = MainWindowCoordinator(appState: appState)
    private lazy var recordingOverlayCoordinator = RecordingOverlayCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Published emits the saved preference immediately, before any window opens.
        appearanceSubscription = appState.$appAppearance
            .removeDuplicates()
            .sink { [weak self] appearance in
                self?.appearanceService.apply(appearance)
            }

        appState.attach(mainWindowRouter: mainWindowCoordinator)
        appState.attach(recordingOverlayRouter: recordingOverlayCoordinator)
        appState.handleApplicationLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            appState.showMainWindow()
        }

        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.prepareForTermination()
    }
}
