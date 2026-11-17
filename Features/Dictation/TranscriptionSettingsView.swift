import SwiftUI

struct TranscriptionSettingsView: View {
    @ObservedObject var appState: DictaFlowAppState
    private let pickerWidth: CGFloat = 200
    private var model: WhisperModelDescriptor { appState.whisperConfiguration.model }
    private var prepared: Bool { appState.isWhisperModelPrepared(model) }

    private var isLiquid: Bool { appState.whisperConfiguration.recognitionProvider == .liquid }
    private var liquidReady: Bool { appState.agentVoice?.isModelReady == true }
    private var liquidDownloading: Bool { appState.agentVoice?.isDownloading == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLiquid {
                if !liquidReady {
                    EmberErrorBanner(title: "Download your speech model", message: "Liquid LFM3-Audio-2B is selected, but its shared assets are missing. Download them in Agent Voice, under Models.", actionTitle: "Open Agent Voice") {
                        appState.showMainWindowPage(.agentVoice)
                    }
                    .padding(.bottom, 18)
                }
            } else if !prepared {
                EmberErrorBanner(title: "Download your speech model", message: "Whisper \(model.displayName) is selected, but its local file is missing. Download it or choose an installed model.", actionTitle: "Choose a speech model") {
                    appState.showSpeechModels(focusing: model)
                }
                .padding(.bottom, 18)
            }
            EmberSectionHeading(title: "Speech model")
            SelectedModelCard(name: appState.whisperConfiguration.speechModelName,
                              providerAsset: appState.whisperConfiguration.recognitionProvider.iconName,
                              status: isLiquid ? (liquidReady ? "Ready" : liquidDownloading ? "Downloading…" : "Download needed") : (prepared ? "Ready" : "Download needed"),
                              size: isLiquid ? "1.4 GB" : model.approximateDiskSizeDescription + (appState.isWhisperEncoderPrepared(model) ? " · Neural Engine" : ""),
                              hasError: isLiquid ? !liquidReady : !prepared,
                              actionTitle: (isLiquid ? liquidReady : prepared) ? "Change…" : "Download…",
                              disabled: appState.whisperSettingsLocked) {
                if isLiquid { appState.showSpeechModels() } else { appState.showSpeechModels(focusing: model) }
            }
            .padding(.bottom, 18)
            if isLiquid {
                Text("Liquid LFM3-Audio-2B uses the same press-to-start, press-to-stop recording flow. Download its shared ASR/TTS assets in Agent Voice, under Models. Vocabulary replacements still apply; Whisper decoding hints are not used.")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText).padding(.bottom, 18)
            }
            EmberPanel {
                EmberRow(title: "Task") {
                    selectionMenu(label: "Task", title: appState.whisperConfiguration.taskMode == .transcribe ? "Transcribe" : "Translate to English") {
                        Picker("Task", selection: Binding(get: { appState.whisperConfiguration.taskMode }, set: { appState.updateTaskMode($0) })) {
                            Text("Transcribe").tag(WhisperTaskMode.transcribe)
                            Text("Translate to English").tag(WhisperTaskMode.translateToEnglish)
                        }
                        .pickerStyle(.inline).labelsHidden()
                    }
                }
                EmberDivider()
                EmberRow(title: "Input language") {
                    selectionMenu(label: "Input language", title: appState.whisperConfiguration.inputLanguage.displayName) {
                        Picker("Input language", selection: Binding(get: { appState.whisperConfiguration.inputLanguage }, set: { appState.updateInputLanguage($0) })) {
                            Text("Auto Detect").tag(WhisperInputLanguage.automatic)
                            Section("Common") {
                                ForEach(appState.commonWhisperLanguages) { Text($0.displayName).tag($0.inputLanguage) }
                            }
                            Section("All supported languages") {
                                ForEach(appState.additionalWhisperLanguages) { Text($0.displayName).tag($0.inputLanguage) }
                            }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    }
                }
                .disabled(appState.whisperConfiguration.recognitionProvider == .liquid)
            }
            .disabled(appState.whisperSettingsLocked)
            .padding(.bottom, 18)
            EmberPanel {
                DisclosureGroup {
                    CustomVocabularyEditor(appState: appState).padding(.top, 15)
                } label: {
                    HStack {
                        Text("Vocabulary")
                        Spacer()
                        Text("\(appState.enabledVocabularyTerms.count) active").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .disclosureGroupStyle(EmberDisclosureGroupStyle())
                .font(.system(size: 12)).padding(17)
                EmberDivider().padding(.horizontal, 18)
                DisclosureGroup {
                    soundCues.padding(.top, 15)
                } label: {
                    HStack {
                        Text("Sound cues")
                        Spacer()
                        Text(appState.soundCuesEnabled ? appState.soundCueStyle.title : "Off").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .disclosureGroupStyle(EmberDisclosureGroupStyle())
                .font(.system(size: 12)).padding(17)
            }
        }
    }

    private func selectionMenu<Content: View>(label: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(width: pickerWidth)
            .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label).accessibilityValue(title)
    }

    private var soundCues: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 14) {
                Text("Play sound cues")
                Spacer(minLength: 12)
                Toggle("Play sound cues", isOn: Binding(get: { appState.soundCuesEnabled }, set: { appState.updateSoundCuesEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel("Play sound cues")
            }
            HStack(spacing: 14) {
                Text("Sound style")
                Spacer(minLength: 12)
                selectionMenu(label: "Sound style", title: appState.soundCueStyle.title) {
                    Picker("Sound style", selection: Binding(get: { appState.soundCueStyle }, set: { appState.updateSoundCueStyle($0) })) {
                        ForEach(SoundCueStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                .disabled(!appState.soundCuesEnabled)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(SoundCue.allCases) { cue in
                    Button { appState.previewSoundCue(cue) } label: { Label(cue.title, systemImage: "play.fill") }
                        .buttonStyle(EmberButtonStyle())
                        .accessibilityLabel("Preview \(cue.title.lowercased()) sound")
                }
            }
            .disabled(!appState.soundCuesEnabled)
            if let message = appState.soundCuePlaybackMessage {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text(message).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
        .disabled(appState.whisperSettingsLocked)
    }
}
