import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        EmberColumns(ratio: 1.15, gap: 26) {
            VStack(alignment: .leading, spacing: 0) {
                EmberModuleHeading(title: "Shortcuts & audio")
                EmberSectionHeading(title: "Global shortcut")
                GlobalShortcutSettingsContent(appState: appState)
                    .padding(.bottom, 18)
                EmberSectionHeading(title: "During recording")
                EmberPanel {
                    EmberRow(title: "System audio") {
                        Picker("System audio during recording", selection: Binding(
                            get: { appState.recordingPlaybackBehavior },
                            set: { appState.updateRecordingPlaybackBehavior($0) }
                        )) {
                            Text("Unchanged").tag(RecordingPlaybackBehavior.unchanged)
                            Text("Lower").tag(RecordingPlaybackBehavior.lowerSystemVolume)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 157)
                        .disabled(appState.whisperSettingsLocked)
                    }
                    EmberDivider()
                    EmberRow(title: "Pause supported apps") {
                        Text("Coming soon").font(.system(size: 11))
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                EmberModuleHeading(title: "Storage")
                EmberPanel {
                    EmberRow(title: "Models") {
                        Button { appState.openModelsFolder() } label: {
                            Label("Open storage folder", systemImage: "folder")
                        }
                        .buttonStyle(EmberButtonStyle())
                    }
                }
            }
        }
        .onDisappear { appState.cancelGlobalShortcutEditing() }
    }
}
