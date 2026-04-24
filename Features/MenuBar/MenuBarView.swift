import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DictaFlow")
                    .font(.headline)

                Text(appState.menuBarStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(appState.dictationSummaryText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(appState.hotkeyDisplayText)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)

            Divider()

            Button(appState.dictationActionTitle) {
                appState.toggleDictation()
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.recordingState.isRecording ? .red : .accentColor)

            Button("Insert Last Transcript Again") {
                appState.insertLastTranscription()
            }
            .buttonStyle(.bordered)
            .disabled(!appState.canInsertLastTranscription)

            Button("Copy Last Transcript") {
                appState.copyLastTranscription()
            }
            .buttonStyle(.bordered)
            .disabled(!appState.canCopyLastTranscription)

            Button("Refresh Accessibility Status") {
                appState.refreshAccessibilityPermissionStatus()
            }
            .buttonStyle(.bordered)

            Button("Open Accessibility Settings") {
                appState.openAccessibilitySettings()
            }
            .buttonStyle(.bordered)

            Button("Retry Model Preparation") {
                appState.retryModelPreparation()
            }
            .buttonStyle(.bordered)

            Button(appState.isMainWindowVisible ? "Hide Main Window" : "Open Main Window") {
                appState.toggleMainWindow()
            }
            .buttonStyle(.borderless)

            if let lastTextInsertion = appState.lastTextInsertion {
                Divider()

                Text(lastTextInsertion.summaryText)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                Text(lastTextInsertion.method.detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let lastTranscription = appState.lastTranscription, !lastTranscription.text.isEmpty {
                Divider()

                Text(lastTranscription.text)
                    .font(.caption)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let lastCapture = appState.lastCapture {
                Text(lastCapture.durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Quit DictaFlow") {
                appState.quit()
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

struct MenuBarIconView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        Image(systemName: appState.menuBarIconName)
            .accessibilityLabel("DictaFlow")
    }
}
