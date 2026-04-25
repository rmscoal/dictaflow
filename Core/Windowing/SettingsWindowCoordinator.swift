import AppKit

@MainActor
final class SettingsWindowCoordinator: SettingsWindowRouting {
    private let appState: DictaFlowAppState

    init(appState: DictaFlowAppState) {
        self.appState = appState
    }

    func showSettingsWindow() {
        appState.showMainWindowPage(.settings)
    }
}
