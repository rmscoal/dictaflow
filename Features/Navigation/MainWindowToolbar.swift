import SwiftUI

struct MainWindowToolbar: View {
    @ObservedObject var appState: DictaFlowAppState
    let sidebarCollapsed: Bool
    let toggleSidebar: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleSidebar) { Image(systemName: "sidebar.left") }
                .buttonStyle(EmberIconButtonStyle())
                .help(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
                .accessibilityLabel(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            Text(appState.mainWindowPage.title).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 8)
            if let activity = appState.modelDownloadActivity {
                Button { appState.openDownloadActivity(activity) } label: {
                    Image(systemName: activity.hasFailed ? "exclamationmark.circle" : "arrow.down.circle")
                        .foregroundStyle(activity.hasFailed ? AppTheme.errorText : AppTheme.secondaryText)
                }
                .buttonStyle(EmberIconButtonStyle())
                .background(activity.hasFailed ? AppTheme.errorFill : .clear, in: RoundedRectangle(cornerRadius: 7))
                .help(activity.title).accessibilityLabel(activity.title)
            }
            Button { appState.toggleDictation() } label: {
                Label(recordTitle, systemImage: appState.recordingState.isRecording ? "stop" : "mic")
            }
            .buttonStyle(EmberButtonStyle(primary: true))
            .disabled(appState.isDictationActionDisabled)
            .accessibilityIdentifier("record-button")
        }
        .padding(.horizontal, AppLayout.contentPadding)
        .frame(height: AppLayout.headerHeight)
    }

    private var recordTitle: String {
        if appState.recordingState.isRecording { return "Stop recording" }
        if appState.recordingState != .idle { return "Preparing…" }
        if appState.transcriptionState.isBusy || appState.textInsertionState.isBusy { return "Processing…" }
        return "Start dictation"
    }
}
