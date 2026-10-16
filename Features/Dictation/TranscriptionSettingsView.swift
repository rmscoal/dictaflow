import SwiftUI

struct TranscriptionSettingsView: View {
    @ObservedObject var appState: DictaFlowAppState
    private var model: WhisperModelDescriptor { appState.whisperConfiguration.model }
    private var prepared: Bool { appState.isWhisperModelPrepared(model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !prepared {
                EmberErrorBanner(title: "Download your speech model", message: "Whisper \(model.displayName) is selected, but its local file is missing. Download it or choose an installed model.", actionTitle: "Choose a speech model") {
                    appState.showSpeechModels(focusing: model)
                }
                .padding(.bottom, 18)
            }
            EmberSectionHeading(title: "Speech model")
            SelectedModelCard(name: "Whisper \(model.displayName)", providerAsset: "provider-openai",
                              status: prepared ? "Ready" : "Download needed",
                              size: model.approximateDiskSizeDescription + (appState.isWhisperEncoderPrepared(model) ? " · Neural Engine" : ""),
                              hasError: !prepared, actionTitle: prepared ? "Change…" : "Download…", disabled: appState.whisperSettingsLocked) {
                appState.showSpeechModels()
            }
            .padding(.bottom, 18)
            EmberColumns(ratio: 1, gap: 12, stackingWidth: 420) {
                field(title: "Task") {
                    Picker("Task", selection: Binding(get: { appState.whisperConfiguration.taskMode }, set: { appState.updateTaskMode($0) })) {
                        Text("Transcribe").tag(WhisperTaskMode.transcribe)
                        Text("To English").tag(WhisperTaskMode.translateToEnglish)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                field(title: "Input language") {
                    Picker("Input language", selection: Binding(get: { appState.whisperConfiguration.inputLanguage }, set: { appState.updateInputLanguage($0) })) {
                        Text("Automatic").tag(WhisperInputLanguage.automatic)
                        Section("Common") {
                            ForEach(appState.commonWhisperLanguages) { Text($0.displayName).tag($0.inputLanguage) }
                        }
                        Section("All supported languages") {
                            ForEach(appState.additionalWhisperLanguages) { Text($0.displayName).tag($0.inputLanguage) }
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
            }
            .disabled(appState.whisperSettingsLocked)
            .padding(.bottom, 18)
            EmberPanel {
                DisclosureGroup {
                    CustomVocabularyEditor(appState: appState).padding(.top, 15)
                } label: {
                    HStack {
                        Text("Custom vocabulary")
                        Spacer()
                        Text("\(appState.whisperConfiguration.customVocabulary.count) words").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
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

    private func field<Control: View>(title: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
            control().font(.system(size: 12)).frame(maxWidth: .infinity)
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(AppTheme.border, lineWidth: 1) }
    }

    private var soundCues: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle("Play sound cues", isOn: Binding(get: { appState.soundCuesEnabled }, set: { appState.updateSoundCuesEnabled($0) }))
                .toggleStyle(.switch).controlSize(.mini)
            Picker("Sound style", selection: Binding(get: { appState.soundCueStyle }, set: { appState.updateSoundCueStyle($0) })) {
                ForEach(SoundCueStyle.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!appState.soundCuesEnabled)
            HStack(spacing: 8) {
                ForEach(SoundCue.allCases) { cue in
                    Button { appState.previewSoundCue(cue) } label: { Label(cue.title, systemImage: "play.fill") }
                        .buttonStyle(EmberButtonStyle())
                        .accessibilityLabel("Preview \(cue.title.lowercased()) sound")
                }
            }
            .disabled(!appState.soundCuesEnabled)
            if let message = appState.soundCuePlaybackMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            }
        }
        .disabled(appState.whisperSettingsLocked)
    }
}
