import AppKit

final class DictaFlowAppDelegate: NSObject, NSApplicationDelegate {
    let appState = DictaFlowAppState()
    private lazy var mainWindowCoordinator = MainWindowCoordinator(appState: appState)

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.attach(mainWindowRouter: mainWindowCoordinator)
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
