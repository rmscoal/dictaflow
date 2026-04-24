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

            Button("Retry Model Preparation") {
                appState.retryModelPreparation()
            }
            .buttonStyle(.bordered)

            Button("Refresh Microphone Status") {
                appState.refreshMicrophonePermissionStatus()
            }
            .buttonStyle(.bordered)

            Button(appState.isMainWindowVisible ? "Hide Main Window" : "Open Main Window") {
                appState.toggleMainWindow()
            }
            .buttonStyle(.borderless)

            if let lastTranscription = appState.lastTranscription, !lastTranscription.text.isEmpty {
                Divider()

                Text(lastTranscription.text)
                    .font(.caption)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                Text(lastTranscription.detectedLanguageDisplayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        .frame(width: 320, alignment: .leading)
    }
}

struct MenuBarIconView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        Image(systemName: appState.menuBarIconName)
            .accessibilityLabel("DictaFlow")
    }
}
