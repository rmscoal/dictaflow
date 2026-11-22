import SwiftUI

struct MenuBarView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appState: DictaFlowAppState
    var modelMigrationNotice: String?
    var legacyDataLocations: [URL] = []

    var body: some View {
        VStack(spacing: 14) {
            header
            dictationControl
            quickControls
            if let modelMigrationNotice {
                Text(modelMigrationNotice).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            }
            if !legacyDataLocations.isEmpty {
                Button("Show previous DictaFlow data in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(legacyDataLocations)
                }
                .buttonStyle(EmberInlineActionButtonStyle())
                .help("These are the old private data folders. Keep using Omdo after upgrading.")
            }
            footer
        }
        .padding(16)
        .frame(width: 364)
        .foregroundStyle(AppTheme.primaryText)
        .omdoFloatingWindowBackground(in: Rectangle(), showsRim: false)
        .tint(AppTheme.accent)
    }

    private var header: some View {
        HStack(spacing: 9) {
            EmberAppMark(size: 26)
            Text("Omdo").font(.system(size: 14, weight: .semibold))
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(EmberIconButtonStyle())
                .accessibilityLabel("Close Omdo menu")
        }
    }

    private var quickControls: some View {
        EmberPanel {
            transcriptionMenu
            EmberDivider()
            HStack(spacing: 6) {
                refinementMenu
                Toggle("Enable refinement", isOn: Binding(
                    get: { appState.refinementConfiguration.isEnabled },
                    set: { enabled in
                        appState.updateRefinementEnabled(enabled)
                        if enabled && !appState.refinementConfiguration.isEnabled {
                            dismiss()
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(EmberSwitchStyle(
                    showsLabel: false,
                    contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 11)
                ))
                .controlSize(.small)
                .disabled(appState.refinementSettingsLocked)
            }
            EmberDivider()
            if let voice = appState.agentVoice {
                MenuBarAgentVoiceRow(voice: voice)
            } else {
                EmberRow(title: "Agent Voice", detail: "Unavailable", asset: SpeechRecognitionProvider.liquid.iconName) { EmptyView() }
            }
        }
    }

    private var transcriptionMenu: some View {
        let configuration = appState.whisperConfiguration
        return modelMenu("Transcription", modelName: configuration.speechModelName,
                         asset: configuration.recognitionProvider.iconName) {
            ForEach(WhisperModelDescriptor.allCases.filter { appState.isWhisperModelPrepared($0) }, id: \.self) { model in
                modelOption("Whisper \(model.displayName)",
                            selected: configuration.recognitionProvider == .whisper && configuration.model == model,
                            disabled: appState.whisperSettingsLocked) {
                    guard !appState.whisperSettingsLocked else { return }
                    if !appState.isWhisperModelPrepared(model) { dismiss() }
                    appState.updateWhisperModel(model)
                }
            }
            if appState.agentVoice?.isModelReady == true {
                modelOption("Liquid LFM3-Audio-2B", selected: configuration.recognitionProvider == .liquid,
                            disabled: appState.whisperSettingsLocked) {
                    guard !appState.whisperSettingsLocked else { return }
                    guard appState.agentVoice?.isModelReady == true else {
                        dismiss()
                        appState.agentVoiceTab = .general
                        appState.showMainWindowPage(.agentVoice)
                        return
                    }
                    appState.updateSpeechToLiquid()
                }
            }
            Divider()
            Button("Manage speech models…") {
                dismiss()
                appState.showSpeechModels()
            }
        }
    }

    private var refinementMenu: some View {
        let selectedModel = appState.refinementConfiguration.model
        return modelMenu("Refinement", modelName: selectedModel.displayName, asset: selectedModel.provider?.iconName) {
            ForEach(RefinementModelDescriptor.allCases.filter {
                appState.isRefinementModelPrepared($0) && appState.isRefinementModelSupported($0)
            }, id: \.self) { model in
                modelOption(model.displayName, selected: model == selectedModel,
                            disabled: appState.refinementSettingsLocked || !appState.isRefinementRuntimeAvailable) {
                    guard !appState.refinementSettingsLocked else { return }
                    guard appState.isRefinementRuntimeAvailable,
                          appState.isRefinementModelPrepared(model),
                          appState.isRefinementModelSupported(model) else {
                        dismiss()
                        appState.showRefinementModels(focusing: model)
                        return
                    }
                    appState.updateRefinementModel(model)
                }
            }
            Divider()
            Button("Manage refinement models…") {
                dismiss()
                appState.showRefinementModels()
            }
        }
    }

    @ViewBuilder
    private var dictationControl: some View {
        let recording = appState.recordingState.isRecording
        let title = recording ? "Stop recording" : "Start dictation"
        if let dictationProgress {
            Text(dictationProgress)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 12)
        } else {
            Button {
                appState.toggleDictation()
            } label: {
                HStack(spacing: 8) {
                    Label(title, systemImage: recording ? "stop.fill" : "mic")
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                    ShortcutKeycaps(shortcut: appState.globalShortcut, onPrimary: true)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(EmberButtonStyle(primary: true))
            .disabled(appState.isDictationActionDisabled)
            .accessibilityLabel(title)
            .accessibilityHint("Keyboard shortcut: \(appState.hotkeyDisplayText)")
        }
    }

    private var dictationProgress: String? {
        switch appState.recordingState {
        case .requestingPermission:
            return "Waiting for microphone permission…"
        case .starting:
            return "Starting dictation…"
        case .stopping:
            return "Finishing recording…"
        case .recording:
            return nil
        case .idle:
            if appState.isHistoryProcessing { return "Processing saved audio…" }
            if appState.transcriptionState.isBusy || appState.textInsertionState.isBusy {
                return appState.menuBarStatusText
            }
            return nil
        }
    }

    private var footer: some View {
        HStack {
            Button {
                dismiss()
                appState.showMainWindowPage(.dictation)
            } label: {
                Label("Settings…", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(EmberInlineActionButtonStyle())
            .accessibilityLabel("Open Dictation settings")
            Spacer()
            Button("Quit") { appState.quit() }
                .buttonStyle(EmberInlineActionButtonStyle())
                .foregroundStyle(AppTheme.secondaryText)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 2)
    }

    private func modelMenu<Items: View>(
        _ title: String,
        modelName: String,
        asset: String?,
        @ViewBuilder items: () -> Items
    ) -> some View {
        Menu(content: items) {
            HStack(spacing: 10) {
                if let asset {
                    EmberProviderIcon(asset: asset, size: 26)
                } else {
                    Image(systemName: "wand.and.stars").frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(modelName).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(EmberButtonStyle(appearance: .plain))
        .menuIndicator(.hidden)
        .accessibilityLabel(title + " model")
        .accessibilityValue(modelName)
    }

    private func modelOption(_ name: String, selected: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
        .disabled(disabled || selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MenuBarAgentVoiceRow: View {
    @ObservedObject var voice: AgentVoiceCoordinator

    var body: some View {
        Toggle(isOn: Binding(get: { voice.isEnabled }, set: { voice.setEnabled($0) })) {
            HStack(spacing: 10) {
                EmberProviderIcon(asset: SpeechRecognitionProvider.liquid.iconName, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent Voice").font(.system(size: 12, weight: .medium))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(voice.activeError?.scope == .setup ? AppTheme.errorText : AppTheme.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(EmberSwitchStyle(contentInsets: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 11)))
        .controlSize(.small)
        .accessibilityHint(detail ?? "")
    }

    private var detail: String? {
        if let error = voice.activeError, error.scope == .setup { return error.message }
        guard voice.isEnabled, !voice.isModelReady else { return nil }
        return voice.isDownloading ? "Downloading speech model…" : "Speech model needed"
    }
}
