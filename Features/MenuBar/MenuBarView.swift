import SwiftUI

struct MenuBarView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appState: DictaFlowAppState
    private var listening: Bool { appState.recordingState.isRecording }
    private var processing: Bool { appState.transcriptionState.isBusy || appState.textInsertionState.isBusy || appState.isHistoryProcessing }
    private var preparing: Bool { appState.recordingState != .idle && !listening }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                EmberAppMark(size: 24)
                Text("DictaFlow").font(.system(size: 13, weight: .medium))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(EmberIconButtonStyle()).accessibilityLabel("Close DictaFlow menu")
            }
            .padding(.horizontal, 4).padding(.bottom, 14)
            capturePanel
            VStack(spacing: 0) {
                pipelineRow(.transcription, title: "Transcription", detail: "Whisper \(appState.whisperConfiguration.model.displayName)", asset: "provider-openai")
                EmberDivider()
                pipelineRow(.refinement, title: "Refinement", detail: appState.refinementConfiguration.isEnabled ? appState.refinementConfiguration.model.displayName : "Off", asset: appState.refinementConfiguration.model.provider?.iconName)
                EmberDivider()
                pipelineRow(.tone, title: "Tone", detail: appState.textTone.title, asset: nil)
            }
            .padding(.top, 7)
            EmberDivider()
            HStack {
                Button { dismiss(); appState.showMainWindowPage(.history) } label: { Label("History", systemImage: "clock") }
                Spacer()
                Button { dismiss(); appState.openSettingsWindow() } label: { Label("Settings…", systemImage: "slider.horizontal.3") }
            }
            .buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 7).padding(.vertical, 17)
            EmberDivider()
            HStack {
                Button {
                    dismiss()
                    appState.showMainWindowPage(.updates)
                    appState.checkForUpdates()
                } label: { Label("Check for updates…", systemImage: "arrow.triangle.2.circlepath") }
                Spacer()
                Button("Quit") { appState.quit() }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            .padding(.horizontal, 7).padding(.top, 16).padding(.bottom, 4)
        }
        .padding(14).frame(width: 360)
        .foregroundStyle(AppTheme.primaryText).background { EmberMaterialFill(tint: AppTheme.glass) }.tint(AppTheme.accent)
    }

    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(listening ? "Recording" : processing ? "Processing" : preparing ? "Preparing" : "Ready")
                        .font(.system(size: 19, weight: .medium))
                    if processing || preparing {
                        Text(appState.menuBarStatusText).font(.system(size: 11)).foregroundStyle(AppTheme.paperSecondaryText)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(appState.globalShortcut.displayParts) { part in
                                if let symbol = part.symbol { Image(systemName: symbol) }
                                else { Text(part.title) }
                            }
                            Text(listening ? "to stop" : "to start")
                        }
                        .font(.system(size: 11)).foregroundStyle(AppTheme.paperSecondaryText)
                        .accessibilityLabel("\(appState.hotkeyDisplayText) to \(listening ? "stop" : "start")")
                    }
                }
                Spacer(minLength: 0)
                Button { appState.toggleDictation() } label: {
                    Image(systemName: listening ? "stop" : "mic").font(.system(size: 21))
                        .frame(width: 54, height: 54)
                        .foregroundStyle(AppTheme.actionText).background(AppTheme.actionFill, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).disabled(appState.isDictationActionDisabled)
                .accessibilityLabel(listening ? "Stop recording" : "Start dictation")
            }
            HStack(spacing: 3) {
                ForEach(Array([12.0, 22, 14, 25, 9, 17, 23, 13, 19, 10, 25, 18, 12, 20, 15, 22, 11, 18, 26, 15, 20, 10, 16, 12].enumerated()), id: \.offset) { _, height in
                    Capsule().fill(AppTheme.accent.opacity(listening ? 0.85 : 0.4)).frame(width: 3, height: height)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 27).accessibilityHidden(true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(AppTheme.paperText)
        .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.paperBorder, lineWidth: 1) }
    }

    private func pipelineRow(_ tab: DictationSettingsTab, title: String, detail: String, asset: String?) -> some View {
        Button { dismiss(); appState.showDictationSettings(tab) } label: {
            HStack(spacing: 10) {
                if let asset { EmberProviderIcon(asset: asset, size: 23) }
                else { EmberAppMark(size: 23) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12))
                    Text(detail).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 7).padding(.vertical, 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Open \(title). \(detail)")
    }
}
