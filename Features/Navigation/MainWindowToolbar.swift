import SwiftUI

struct MainWindowToolbar: View {
    @ObservedObject var appState: DictaFlowAppState
    let sidebarCollapsed: Bool
    let toggleSidebar: () -> Void
    @State private var showsDownloads = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let activities = appState.activeDownloadActivities
        HStack(spacing: 12) {
            Button(action: toggleSidebar) { Image(systemName: "sidebar.left") }
                .buttonStyle(EmberIconButtonStyle())
                .help(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
                .accessibilityLabel(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
            Text(appState.mainWindowPage.title).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 8)
            if !activities.isEmpty {
                downloadButton(count: activities.count)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: activities.count)
        .onChange(of: activities.isEmpty) { _, isEmpty in
            if isEmpty { showsDownloads = false }
        }
    }

    private func downloadButton(count: Int) -> some View {
        Button { showsDownloads.toggle() } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 32, height: 32)
                .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(AppTheme.border, lineWidth: 1)
                }
                .overlay(alignment: .topTrailing) {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .padding(.horizontal, 1)
                        .background(AppTheme.destructive, in: Capsule())
                        .overlay { Capsule().stroke(AppTheme.background, lineWidth: 1.5) }
                        .offset(x: 5, y: -5)
                        .accessibilityHidden(true)
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(count == 1 ? "Show download in progress" : "Show \(count) downloads in progress")
        .accessibilityLabel(count == 1 ? "Show download in progress" : "Show downloads in progress")
        .accessibilityValue(count == 1 ? "1 download" : "\(count) downloads")
        .accessibilityIdentifier("downloads-button")
        .popover(isPresented: $showsDownloads, arrowEdge: .top) {
            DownloadActivitiesPopover(appState: appState, isPresented: $showsDownloads)
        }
    }

    private var recordTitle: String {
        if appState.recordingState.isRecording { return "Stop recording" }
        if appState.recordingState != .idle { return "Preparing…" }
        if appState.transcriptionState.isBusy || appState.textInsertionState.isBusy { return "Processing…" }
        return "Start dictation"
    }
}
