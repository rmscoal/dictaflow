import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: DictaFlowAppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                currentDefaultsSection
                globalShortcutSection
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

    private var globalShortcutSection: some View {
        GroupBox("Global Shortcut") {
            GlobalShortcutSettingsContent(appState: appState)
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
                            .disabled(!appState.isWhisperModelPrepared(model))
                    }
                }
                .pickerStyle(.menu)
                .disabled(appState.whisperSettingsLocked)

                Label(
                    "\(appState.whisperConfiguration.model.displayName) • \(appState.whisperConfiguration.model.approximateDiskSizeDescription)",
                    systemImage: "cpu"
                )
                .font(.headline)

                Text(appState.whisperConfiguration.model.detailText)
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
                    Button("Open Models Folder") {
                        appState.openModelsFolder()
                    }
                    .buttonStyle(.bordered)
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
            get: { appState.whisperConfiguration.model },
            set: { appState.updateWhisperModel($0) }
        )
    }

    private var headerDetailText: String {
        if appState.whisperSettingsLocked {
            return "Settings are temporarily locked while DictaFlow is recording, preparing a model, transcribing, or inserting text."
        }

        return "Changes are saved immediately and apply to the next recording."
    }

    private var modelPreparationStatusText: String {
        return appState.modelStatusText
    }
}
