import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var isShowingModelPreparationConfirmation = false
    @State private var selectedModel: WhisperModelDescriptor
    @State private var selectedRefinementModel: RefinementModelDescriptor

    init(appState: DictaFlowAppState) {
        self.appState = appState
        _selectedModel = State(initialValue: appState.whisperConfiguration.model)
        _selectedRefinementModel = State(initialValue: appState.refinementConfiguration.model)
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
        .frame(minWidth: 500, minHeight: 340)
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
        HStack(spacing: 10) {
            Image(systemName: appState.menuBarIconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("DictaFlow")
                    .font(.system(size: 14, weight: .semibold))
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
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 7)
        .background(AppTheme.barFill)
    }

    private var dashboardPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                recordingTile
                refinementTile

                LazyVGrid(columns: compactNavigationColumns, spacing: 6) {
                    NavigationTile(title: "Model", value: appState.whisperConfiguration.model.displayName, systemImage: "cpu") {
                        appState.mainWindowPage = .models
                    }

                    NavigationTile(title: "Settings", value: "Preferences", systemImage: "slider.horizontal.3") {
                        appState.mainWindowPage = .settings
                    }

                    NavigationTile(title: "History", value: historySummaryText, systemImage: "clock") {
                        appState.mainWindowPage = .history
                    }
                }

                GlassTile {
                    VStack(alignment: .leading, spacing: 6) {
                        StatusLine(
                            title: "Microphone",
                            value: appState.microphonePermissionState.title,
                            systemImage: "mic.fill",
                            color: appState.microphonePermissionState == .granted ? AppTheme.primaryText : AppTheme.secondaryText
                        )

                        StatusLine(
                            title: "Accessibility",
                            value: appState.accessibilityPermissionState.title,
                            systemImage: "figure.wave.circle",
                            color: appState.accessibilityPermissionState == .granted ? AppTheme.primaryText : AppTheme.secondaryText
                        )

                        if hasMissingRequiredSettings {
                            Button("Refresh") {
                                appState.refreshMicrophonePermissionStatus()
                                appState.refreshAccessibilityPermissionStatus()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: 430, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var refinementTile: some View {
        GlassTile {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refined Text with LLM")
                            .font(.system(size: 11, weight: .semibold))

                        Text(appState.refinementConfiguration.isEnabled ? "On" : "Off")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Toggle("", isOn: refinementEnabledBinding)
                        .labelsHidden()
                        .toggleStyle(AppCompactSwitchStyle())
                        .disabled(appState.whisperSettingsLocked)
                }

                Text(shortRefinementStatusText)
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)

                if appState.refinementConfiguration.isEnabled {
                    HStack(spacing: 8) {
                        Button {
                            appState.prepareRefinementModel()
                        } label: {
                            Label("Prepare", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appState.whisperSettingsLocked)

                        Button {
                            appState.mainWindowPage = .settings
                        } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else if !appState.hasPreparedRefinementModel {
                    HStack(spacing: 8) {
                        Button {
                            appState.mainWindowPage = .settings
                        } label: {
                            Label("Choose Model", systemImage: "list.bullet")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(AppTheme.accent)

                        Text("Qwen2.5 1.5B (Recommended)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(AppTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var recordingTile: some View {
        GlassTile {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.045))
                            .overlay(Circle().stroke(AppTheme.border, lineWidth: 0.75))

                        Image(systemName: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.recordingState.isRecording ? "Recording" : "Ready")
                            .font(.system(size: 12, weight: .semibold))

                        Text(appState.dictationSummaryText)
                            .font(.system(size: 10))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    WaveformBadge()
                        .frame(width: 28, height: 18)
                        .foregroundStyle(AppTheme.tertiaryText)
                }

                Button {
                    appState.toggleDictation()
                } label: {
                    Label(appState.dictationActionTitle, systemImage: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(AppTheme.accent)
                .disabled(appState.transcriptionState.isBusy || appState.textInsertionState.isBusy)
            }
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
                                .font(.system(size: 13, weight: .semibold))

                            Spacer()

                            Text(appState.whisperConfiguration.model.approximateDiskSizeDescription)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(AppTheme.accent)
                        }

                        Text(shortModelStatusText)
                            .font(.system(size: 10))
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
                    VStack(alignment: .leading, spacing: 12) {
                        SettingLabel(
                            title: "Refinement",
                            value: appState.refinementConfiguration.isEnabled ? "On" : "Off",
                            systemImage: "wand.and.sparkles"
                        )

                        Toggle("Clean transcripts locally before insertion", isOn: refinementEnabledBinding)
                            .toggleStyle(.switch)
                            .disabled(appState.whisperSettingsLocked)

                        Picker("Model", selection: refinementModelBinding) {
                            ForEach(RefinementModelDescriptor.allCases, id: \.self) { model in
                                Text("\(model.pickerTitle) (\(model.approximateDiskSizeDescription))")
                                    .tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(appState.whisperSettingsLocked)

                        Text(selectedRefinementModel.detailText)
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(shortRefinementStatusText)
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button {
                                appState.prepareAndUseRefinementModel(selectedRefinementModel)
                            } label: {
                                Label("Use & Prepare", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.accent)
                            .disabled(appState.whisperSettingsLocked)

                            Text("Local")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(AppTheme.tertiaryText)
                        }
                    }
                }

                GlassTile {
                    HStack(spacing: 10) {
                        Button {
                            appState.resetWhisperSettingsToDefaults()
                            selectedModel = WhisperConfiguration.default.model
                            selectedRefinementModel = RefinementConfiguration.default.model
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

                            if let refinement = lastTranscription.refinement {
                                Text(refinement.refinedText.isEmpty ? "Empty refined transcript" : refinement.refinedText)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Divider()

                                Text("Raw Whisper Transcript")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AppTheme.secondaryText)

                                Text(lastTranscription.text.isEmpty ? "Empty transcript" : lastTranscription.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(lastTranscription.text.isEmpty ? "Empty transcript" : lastTranscription.text)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

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

    private var compactNavigationColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 0), spacing: 6),
            GridItem(.flexible(minimum: 0), spacing: 6),
            GridItem(.flexible(minimum: 0), spacing: 6)
        ]
    }

    private var statusColor: Color {
        appState.recordingState.isRecording ? AppTheme.primaryText : AppTheme.accent
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

    private var recordingStatusText: String {
        if appState.recordingState.isRecording {
            return "Recording"
        }

        if appState.transcriptionState.isTranscribing {
            return "Transcribing"
        }

        if appState.transcriptionState.isRefining {
            return "Refining"
        }

        if appState.textInsertionState.isBusy {
            return "Inserting"
        }

        return "Idle"
    }

    private var shortModelStatusText: String {
        if let progress = appState.modelDownloadProgressText {
            return progress.replacingOccurrences(of: appState.modelsDirectoryPath, with: "local cache")
        }

        return appState.modelStatusText.replacingOccurrences(of: appState.modelsDirectoryPath, with: "local cache")
    }

    private var shortRefinementStatusText: String {
        appState.refinementStatusText.replacingOccurrences(of: appState.modelsDirectoryPath, with: "local cache")
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

    private var refinementEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.refinementConfiguration.isEnabled },
            set: { appState.updateRefinementEnabled($0) }
        )
    }

    private var refinementModelBinding: Binding<RefinementModelDescriptor> {
        Binding(
            get: { selectedRefinementModel },
            set: { selectedRefinementModel = $0 }
        )
    }

    private func goBackToDashboard() {
        appState.mainWindowPage = .dashboard
    }
}

private enum AppTheme {
    static let background = Color(red: 0.037, green: 0.037, blue: 0.039)
    static let barFill = Color.black.opacity(0.28)
    static let tileFill = Color.white.opacity(0.035)
    static let accent = Color.white.opacity(0.88)
    static let border = Color.white.opacity(0.08)
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
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Button(action: back) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Label(title, systemImage: systemImage)
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()
                }

                content
            }
            .padding(9)
        }
    }
}

private struct GlassTile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.07), radius: 5, x: 0, y: 2)
    }
}

private struct TileHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppTheme.secondaryText)
    }
}

private struct WaveformBadge: View {
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach([5, 10, 16, 12, 6], id: \.self) { height in
                Capsule(style: .continuous)
                    .frame(width: 2.5, height: CGFloat(height))
            }
        }
    }
}

private struct AppCompactSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                configuration.isOn.toggle()
            }
        } label: {
            Capsule(style: .continuous)
                .fill(configuration.isOn ? Color.white.opacity(0.18) : Color.white.opacity(0.10))
                .frame(width: 32, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.white : Color.white.opacity(0.42))
                        .frame(width: 14, height: 14)
                        .padding(2)
                }
                .overlay(Capsule(style: .continuous).stroke(AppTheme.border, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
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
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 9, weight: .semibold))

                        Text(value)
                            .font(.system(size: 8))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
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
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.displayName)
                        .font(.system(size: 11, weight: .semibold))

                    Spacer()

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.accent)
                    }
                }

                Text(model.approximateDiskSizeDescription)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.accent)

                Text(model.detailText)
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? AppTheme.accent.opacity(0.7) : AppTheme.border, lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingLabel: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 14)

            Text(title)
                .font(.system(size: 11, weight: .semibold))

            Spacer()

            Text(value)
                .font(.system(size: 10, weight: .medium))
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
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 12)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer()

            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(minWidth: 52, alignment: .trailing)
        }
    }
}
