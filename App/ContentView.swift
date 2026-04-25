import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var isShowingModelPreparationConfirmation = false
    @State private var selectedModel: WhisperModelDescriptor

    init(appState: DictaFlowAppState) {
        self.appState = appState
        _selectedModel = State(initialValue: appState.whisperConfiguration.model)
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .foregroundStyle(AppTheme.primaryText)
        .alert(
            "Prepare \(selectedModel.displayName) Model?",
            isPresented: $isShowingModelPreparationConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Prepare Model") {
                appState.prepareAndUseModel(selectedModel)
            }
        } message: {
            Text("DictaFlow will use \(selectedModel.displayName) for future recordings and download it locally if needed.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.mainWindowPage {
        case .dashboard:
            dashboardPage
        case .models:
            modelsPage
        case .settings:
            settingsPage
        case .history:
            historyPage
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: appState.menuBarIconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("DictaFlow")
                    .font(.system(size: 16, weight: .semibold))

                Text(appState.menuBarStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                appState.mainWindowPage = .settings
            } label: {
                Label(appState.hotkeyDisplayText, systemImage: "keyboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                appState.closeMainWindow()
            } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Hide Window")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(AppTheme.barFill)
    }

    private var dashboardPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    recordingTile

                    VStack(spacing: 8) {
                        NavigationTile(title: "Model", value: appState.whisperConfiguration.model.displayName, systemImage: "cpu") {
                            appState.mainWindowPage = .models
                        }

                        NavigationTile(title: "Settings", value: appState.whisperConfiguration.taskMode.title, systemImage: "slider.horizontal.3") {
                            appState.mainWindowPage = .settings
                        }

                        NavigationTile(title: "History", value: historySummaryText, systemImage: "clock") {
                            appState.mainWindowPage = .history
                        }
                    }
                    .frame(width: 210)
                }

                LazyVGrid(columns: dashboardColumns, spacing: 10) {
                    GlassTile {
                        VStack(alignment: .leading, spacing: 8) {
                            TileHeader(title: "Access", systemImage: "checkmark.shield")

                            StatusLine(
                                title: "Microphone",
                                value: appState.microphonePermissionState.title,
                                systemImage: "mic.fill",
                                color: appState.microphonePermissionState == .granted ? .green : .orange
                            )

                            StatusLine(
                                title: "Accessibility",
                                value: appState.accessibilityPermissionState.title,
                                systemImage: "figure.wave.circle",
                                color: appState.accessibilityPermissionState == .granted ? .green : .orange
                            )

                            if hasMissingRequiredSettings {
                                HStack(spacing: 8) {
                                    Button("Refresh") {
                                        appState.refreshMicrophonePermissionStatus()
                                        appState.refreshAccessibilityPermissionStatus()
                                    }
                                    .controlSize(.small)

                                    if appState.accessibilityPermissionState != .granted {
                                        Button("Open Settings") {
                                            appState.openAccessibilitySettings()
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }

                    GlassTile {
                        VStack(alignment: .leading, spacing: 8) {
                            TileHeader(title: "Local Engine", systemImage: "lock.shield")

                            Text(shortModelStatusText)
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(3)

                            Text(appState.whisperConfigurationSummaryText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AppTheme.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var recordingTile: some View {
        GlassTile {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: appState.dictationActionSymbolName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .symbolRenderingMode(.hierarchical)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.recordingState.isRecording ? "Recording" : "Ready")
                            .font(.system(size: 22, weight: .semibold))

                        Text(appState.dictationSummaryText)
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer()
                }

                Button {
                    appState.toggleDictation()
                } label: {
                    Label(appState.dictationActionTitle, systemImage: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(appState.recordingState.isRecording ? .red : AppTheme.accent)
                .disabled(appState.transcriptionState.isTranscribing || appState.textInsertionState.isBusy)
            }
            .frame(minHeight: 128, alignment: .top)
        }
    }

    private var modelsPage: some View {
        DetailPage(title: "Models", systemImage: "cpu", back: goBackToDashboard) {
            VStack(alignment: .leading, spacing: 14) {
                GlassTile {
                    VStack(alignment: .leading, spacing: 10) {
                        TileHeader(title: "Active Model", systemImage: "cpu")

                        HStack(alignment: .firstTextBaseline) {
                            Text(appState.whisperConfiguration.model.displayName)
                                .font(.system(size: 22, weight: .semibold))

                            Spacer()

                            Text(appState.whisperConfiguration.model.approximateDiskSizeDescription)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(AppTheme.accent)
                        }

                        Text(shortModelStatusText)
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }

                LazyVGrid(columns: dashboardColumns, spacing: 10) {
                    ForEach(WhisperModelDescriptor.allCases, id: \.self) { model in
                        ModelChoiceCard(
                            model: model,
                            isActive: model == appState.whisperConfiguration.model,
                            isSelected: model == selectedModel
                        ) {
                            selectedModel = model
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        if selectedModel == appState.whisperConfiguration.model {
                            appState.retryModelPreparation()
                        } else {
                            isShowingModelPreparationConfirmation = true
                        }
                    } label: {
                        Label(selectedModel == appState.whisperConfiguration.model ? "Prepare" : "Use Model", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(appState.whisperSettingsLocked)

                    Button {
                        appState.openModelsFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var settingsPage: some View {
        DetailPage(title: "Settings", systemImage: "slider.horizontal.3", back: goBackToDashboard) {
            VStack(alignment: .leading, spacing: 14) {
                GlassTile {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingLabel(title: "Task", value: appState.whisperConfiguration.taskMode.title, systemImage: "text.bubble")

                        Picker("Task", selection: taskModeBinding) {
                            ForEach(WhisperTaskMode.allCases, id: \.self) { taskMode in
                                Text(taskMode.title).tag(taskMode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(appState.whisperSettingsLocked)
                    }
                }

                GlassTile {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingLabel(title: "Language", value: appState.whisperConfiguration.inputLanguage.displayName, systemImage: "globe")

                        Picker("Language", selection: inputLanguageBinding) {
                            Text(WhisperInputLanguage.automatic.displayName)
                                .tag(WhisperInputLanguage.automatic)

                            if !appState.commonWhisperLanguages.isEmpty {
                                Divider()

                                Section("Common") {
                                    ForEach(appState.commonWhisperLanguages) { language in
                                        Text(language.displayName)
                                            .tag(language.inputLanguage)
                                    }
                                }
                            }

                            Section("All") {
                                ForEach(appState.additionalWhisperLanguages) { language in
                                    Text(language.displayName)
                                        .tag(language.inputLanguage)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(appState.whisperSettingsLocked)
                    }
                }

                GlassTile {
                    HStack(spacing: 10) {
                        Button {
                            appState.resetWhisperSettingsToDefaults()
                            selectedModel = WhisperConfiguration.default.model
                        } label: {
                            Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(appState.whisperSettingsLocked)

                        Button {
                            appState.mainWindowPage = .models
                        } label: {
                            Label("Models", systemImage: "cpu")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                    }
                }
            }
        }
    }

    private var historyPage: some View {
        DetailPage(title: "History", systemImage: "clock", back: goBackToDashboard) {
            VStack(alignment: .leading, spacing: 14) {
                GlassTile {
                    VStack(alignment: .leading, spacing: 12) {
                        TileHeader(title: "Last Transcript", systemImage: "text.bubble")

                        if let lastTranscription = appState.lastTranscription {
                            HStack {
                                Text(lastTranscription.taskMode.title)
                                    .font(.system(size: 13, weight: .semibold))

                                Spacer()

                                Text(lastTranscription.completedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppTheme.secondaryText)
                            }

                            Text(lastTranscription.text.isEmpty ? "Empty transcript" : lastTranscription.text)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 10) {
                                Button {
                                    appState.insertLastTranscription()
                                } label: {
                                    Label("Insert Again", systemImage: "arrow.uturn.forward")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.accent)
                                .disabled(!appState.canInsertLastTranscription)

                                Button {
                                    appState.copyLastTranscription()
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                .disabled(!appState.canCopyLastTranscription)
                            }
                        } else {
                            Text("No transcript yet.")
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }

                if let lastCapture = appState.lastCapture {
                    GlassTile {
                        VStack(alignment: .leading, spacing: 8) {
                            TileHeader(title: "Last Capture", systemImage: "waveform")

                            Text(lastCapture.durationText)
                                .font(.system(size: 13))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private var dashboardColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 210), spacing: 10),
            GridItem(.flexible(minimum: 210), spacing: 10)
        ]
    }

    private var statusColor: Color {
        appState.recordingState.isRecording ? .red : AppTheme.accent
    }

    private var hasMissingRequiredSettings: Bool {
        appState.microphonePermissionState != .granted || appState.accessibilityPermissionState != .granted
    }

    private var historySummaryText: String {
        if appState.lastTranscription != nil {
            return "Last transcript"
        }

        if appState.lastCapture != nil {
            return "Last capture"
        }

        return "Empty"
    }

    private var shortModelStatusText: String {
        if let progress = appState.modelDownloadProgressText {
            return progress.replacingOccurrences(of: appState.modelsDirectoryPath, with: "local cache")
        }

        return appState.modelStatusText.replacingOccurrences(of: appState.modelsDirectoryPath, with: "local cache")
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

    private func goBackToDashboard() {
        appState.mainWindowPage = .dashboard
    }
}

private enum AppTheme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.064)
    static let barFill = Color(red: 0.075, green: 0.078, blue: 0.086)
    static let tileFill = Color(red: 0.095, green: 0.098, blue: 0.108)
    static let accent = Color.accentColor
    static let border = Color.white.opacity(0.10)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.60)
    static let tertiaryText = Color.white.opacity(0.38)
}

private struct DetailPage<Content: View>: View {
    let title: String
    let systemImage: String
    let back: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(action: back) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Label(title, systemImage: systemImage)
                        .font(.system(size: 18, weight: .semibold))

                    Spacer()
                }

                content
            }
            .padding(14)
        }
    }
}

private struct GlassTile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
    }
}

private struct TileHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.secondaryText)
    }
}

private struct NavigationTile: View {
    let title: String
    let value: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassTile {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))

                        Text(value)
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.tertiaryText)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ModelChoiceCard: View {
    let model: WhisperModelDescriptor
    let isActive: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(model.displayName)
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.accent)
                    }
                }

                Text(model.approximateDiskSizeDescription)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.accent)

                Text(model.detailText)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? AppTheme.accent.opacity(0.7) : AppTheme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingLabel: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 18)

            Text(title)
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
        }
    }
}

private struct StatusLine: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 16)

            Text(title)
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}
