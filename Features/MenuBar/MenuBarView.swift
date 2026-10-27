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
            .padding(.horizontal, 4).padding(.bottom, 10)
            capturePanel
            VStack(spacing: 0) {
                pipelineRow(.transcription, title: "Transcription", detail: "Whisper \(appState.whisperConfiguration.model.displayName)", asset: "provider-openai")
                EmberDivider()
                pipelineRow(.refinement, title: "Refinement", detail: appState.refinementConfiguration.isEnabled ? appState.refinementConfiguration.model.displayName : "Off", asset: appState.refinementConfiguration.model.provider?.iconName)
            }
            .padding(.top, 4)
            EmberDivider()
            HStack {
                Button { dismiss(); appState.showMainWindowPage(.dictation) } label: { Label("Settings…", systemImage: "slider.horizontal.3") }
                    .accessibilityLabel("Open Dictation settings")
                Spacer()
                Button("Quit") { appState.quit() }
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .buttonStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 7).padding(.vertical, 11)
        }
        .padding(12).frame(width: 360)
        .foregroundStyle(AppTheme.primaryText).background { EmberMaterialFill(tint: AppTheme.glass) }.tint(AppTheme.accent)
    }

    // Borderless warm paper tile, distinct as the primary action zone.
    private var capturePanel: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(listening ? AppTheme.destructive : AppTheme.modelActive)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(listening ? "Recording" : processing ? "Processing" : preparing ? "Preparing" : "Ready")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                Group {
                    if processing || preparing {
                        Text(appState.menuBarStatusText)
                            .font(.system(size: 11)).foregroundStyle(AppTheme.paperSecondaryText)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 6) {
                            ShortcutKeycaps(shortcut: appState.globalShortcut)
                            Text(listening ? "to stop" : "to start")
                                .font(.system(size: 11)).foregroundStyle(AppTheme.paperSecondaryText)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(appState.hotkeyDisplayText) to \(listening ? "stop" : "start")")
                    }
                }
                .padding(.leading, 13)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if listening {
                waveform
            }

            Button { appState.toggleDictation() } label: {
                Image(systemName: listening ? "stop" : "mic").font(.system(size: 15))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(AppTheme.actionText).background(AppTheme.actionFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(appState.isDictationActionDisabled)
            .accessibilityLabel(listening ? "Stop recording" : "Start dictation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(AppTheme.paperText)
        .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(Array([12.0, 22, 14, 25, 9, 17, 23, 13, 19, 10, 25, 18].enumerated()), id: \.offset) { _, height in
                Capsule().fill(AppTheme.accent.opacity(0.85))
                    .frame(width: 2.5, height: height * 0.62)
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private func pipelineRow(_ tab: DictationSettingsTab, title: String, detail: String, asset: String?) -> some View {
        Button { dismiss(); appState.showDictationSettings(tab) } label: {
            HStack(spacing: 10) {
                if let asset { EmberProviderIcon(asset: asset, size: 22) }
                else { EmberAppMark(size: 22) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12))
                    Text(detail).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 7).padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Open \(title). \(detail)")
    }
}
