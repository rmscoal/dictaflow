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
                if let error = appDelegate.launchError {
                    Text("Omdo could not open its local data").font(.headline)
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again", action: appDelegate.prepareApplication)
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
