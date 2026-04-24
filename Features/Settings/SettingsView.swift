import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var isShowingModelPreparationConfirmation = false
    @State private var selectedModel: WhisperModelDescriptor

    init(appState: DictaFlowAppState) {
        self.appState = appState
        _selectedModel = State(initialValue: appState.whisperConfiguration.model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                currentDefaultsSection
                taskModeSection
                inputLanguageSection
                modelSection
                storageSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 720, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "Prepare \(selectedModel.displayName) Model?",
            isPresented: $isShowingModelPreparationConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Prepare Model") {
                appState.prepareAndUseModel(selectedModel)
            }
        } message: {
            Text(
                "\(selectedModel.displayName) becomes the default model for future recordings and may download up to \(selectedModel.approximateDiskSizeDescription) into Application Support if it is not already cached."
            )
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.system(size: 30, weight: .semibold))

            Text("Choose how DictaFlow transcribes recordings before inserting text into the current app.")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(headerDetailText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentDefaultsSection: some View {
        GroupBox("Current Defaults") {
            VStack(alignment: .leading, spacing: 10) {
                Label(appState.whisperConfigurationSummaryText, systemImage: "slider.horizontal.3")
                    .font(.headline)

                if selectedModel != appState.whisperConfiguration.model {
                    Text("Pending model selection: \(selectedModel.displayName). Prepare it to make it the active default.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Model storage: \(appState.modelsDirectoryPath)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var taskModeSection: some View {
        GroupBox("Task Mode") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Task Mode", selection: taskModeBinding) {
                    ForEach(WhisperTaskMode.allCases, id: \.self) { taskMode in
                        Text(taskMode.title).tag(taskMode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(appState.whisperSettingsLocked)

                Text(appState.whisperConfiguration.taskMode.detailText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var inputLanguageSection: some View {
        GroupBox("Input Language") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Input Language", selection: inputLanguageBinding) {
                    Text(WhisperInputLanguage.automatic.displayName)
                        .tag(WhisperInputLanguage.automatic)

                    if !appState.commonWhisperLanguages.isEmpty {
                        Divider()

                        Section("Common Languages") {
                            ForEach(appState.commonWhisperLanguages) { language in
                                Text(language.displayName)
                                    .tag(language.inputLanguage)
                            }
                        }
                    }

                    Section("All Supported Languages") {
                        ForEach(appState.additionalWhisperLanguages) { language in
                            Text(language.displayName)
                                .tag(language.inputLanguage)
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(appState.whisperSettingsLocked)

                Text(appState.whisperConfiguration.inputLanguage.detailText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var modelSection: some View {
        GroupBox("Whisper Model") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Model", selection: modelBinding) {
                    ForEach(WhisperModelDescriptor.allCases, id: \.self) { model in
                        Text("\(model.displayName) (\(model.approximateDiskSizeDescription))")
                            .tag(model)
                    }
                }
                .pickerStyle(.menu)
                .disabled(appState.whisperSettingsLocked)

                Label(
                    "\(selectedModel.displayName) • \(selectedModel.approximateDiskSizeDescription)",
                    systemImage: "cpu"
                )
                .font(.headline)

                Text(selectedModel.detailText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var storageSection: some View {
        GroupBox("Storage & Preparation") {
            VStack(alignment: .leading, spacing: 12) {
                Text(modelPreparationStatusText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("Prepare Selected Model") {
                        if selectedModel == appState.whisperConfiguration.model {
                            appState.retryModelPreparation()
                        } else {
                            isShowingModelPreparationConfirmation = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.whisperSettingsLocked)

                    Button("Open Models Folder") {
                        appState.openModelsFolder()
                    }
                    .buttonStyle(.bordered)

                    Button("Restore Defaults") {
                        appState.updateTaskMode(WhisperConfiguration.default.taskMode)
                        appState.updateInputLanguage(WhisperConfiguration.default.inputLanguage)
                        selectedModel = WhisperConfiguration.default.model
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.whisperSettingsLocked)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var taskModeBinding: Binding<WhisperTaskMode> {
        Binding(
            get: { appState.whisperConfiguration.taskMode },
            set: { appState.updateTaskMode($0) }
        )
    }

    private var inputLanguageBinding: Binding<WhisperInputLanguage> {
        Binding(
            get: { appState.whisperConfiguration.inputLanguage },
            set: { appState.updateInputLanguage($0) }
        )
    }

    private var modelBinding: Binding<WhisperModelDescriptor> {
        Binding(
            get: { selectedModel },
            set: { selectedModel = $0 }
        )
    }

    private var headerDetailText: String {
        if appState.whisperSettingsLocked {
            return "Settings are temporarily locked while DictaFlow is recording, preparing a model, transcribing, or inserting text."
        }

        if selectedModel != appState.whisperConfiguration.model {
            return "Task mode and language save immediately. Model changes become active after you confirm and prepare the selected model."
        }

        return "Changes are saved immediately and apply to the next recording."
    }

    private var modelPreparationStatusText: String {
        if selectedModel != appState.whisperConfiguration.model {
            return "\(selectedModel.displayName) is selected but not active yet. Prepare it to save the new default and download it if needed."
        }

        return appState.modelStatusText
    }
}
