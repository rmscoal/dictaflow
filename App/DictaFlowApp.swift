import SwiftUI

@main
struct DictaFlowApp: App {
    @NSApplicationDelegateAdaptor(DictaFlowAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appDelegate.appState)
        } label: {
            MenuBarIconView(appState: appDelegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
}
