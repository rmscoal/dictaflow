import SwiftUI

@main
struct DictaFlowApp: App {
    @NSApplicationDelegateAdaptor(DictaFlowAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarLaunchContent(appDelegate: appDelegate)
        } label: {
            MenuBarIconView()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLaunchContent: View {
    @ObservedObject var appDelegate: DictaFlowAppDelegate

    var body: some View {
        if let state = appDelegate.appState {
            MenuBarView(appState: state, modelMigrationNotice: appDelegate.modelMigrationNotice,
                        legacyDataLocations: appDelegate.legacyDataLocations)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let migration = appDelegate.migration {
                    Button(action: appDelegate.showMigrationWindow) {
                        Label {
                            Text(migration.error == nil ? "Show upgrade window" : "Show startup issue")
                        } icon: {
                            if migration.error != nil { EmberWarningIcon() }
                            else { Image(systemName: "macwindow") }
                        }
                    }
                    .buttonStyle(EmberButtonStyle())
                } else {
                    ProgressView("Preparing local data…")
                }
                Button("Quit Omdo") { NSApp.terminate(nil) }
            }
            .padding(18)
            .frame(width: 300)
        }
    }
}
