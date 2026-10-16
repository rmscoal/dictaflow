import SwiftUI

struct UpdatesView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        EmberPage {
            EmberPageHeading(title: "Updates")
            HStack(spacing: 14) {
                EmberAppMark(size: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text(appState.appDisplayNameText).font(.system(size: 17, weight: .medium))
                    Text("Version \(appState.appVersionText)").font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                }
            }
            .padding(.bottom, 24)
            EmberPanel {
                EmberRow(title: "Software updates") {
                    if let release = appState.availableUpdate {
                        Button("View \(release.version.displayString)") { appState.openAvailableUpdate() }
                            .buttonStyle(EmberButtonStyle(primary: true))
                    } else {
                        Button(appState.isCheckingForUpdates ? "Checking…" : "Check now") { appState.checkForUpdates() }
                            .buttonStyle(EmberButtonStyle()).disabled(appState.isCheckingForUpdates)
                    }
                }
                EmberDivider()
                EmberRow(title: "Automatic update checks", detail: "Contacts GitHub at most once per day.") {
                    Toggle("Automatic update checks", isOn: Binding(
                        get: { appState.automaticallyChecksForUpdates },
                        set: { appState.updateAutomaticallyChecksForUpdates($0) }
                    )).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
            Text(appState.updateStatusText).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                .padding(.top, 12).accessibilityAddTraits(.updatesFrequently)
        }
    }
}
