import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var isShowingModelPreparationConfirmation = false
    @State private var isShowingUnusedModelDeletionConfirmation = false
    @State private var selectedModel: WhisperModelDescriptor
    @State private var selectedRefinementModel: RefinementModelDescriptor
    @State private var unusedModelDeletionCandidates: [LocalModelFile] = []

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
        .frame(minWidth: AppLayout.windowMinWidth, minHeight: AppLayout.windowMinHeight)
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
        .alert(
            "Delete Unused Models?",
            isPresented: $isShowingUnusedModelDeletionConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button(deleteUnusedModelsButtonTitle, role: .destructive) {
                appState.deleteUnusedModelFiles(matching: unusedModelDeletionCandidates)
                unusedModelDeletionCandidates = []
            }
        } message: {
            Text(unusedModelDeletionConfirmationText)
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
                    .font(.system(size: 18, weight: .semibold))
            }

            Spacer()

            Button {
                appState.mainWindowPage = .settings
            } label: {
                Label(appState.hotkeyDisplayText, systemImage: "keyboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button {
                appState.closeMainWindow()
            } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Hide Window")
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background(AppTheme.barFill)
    }

    private var dashboardPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppLayout.dashboardSpacing) {
                recordingTile
                refinementTile

                LazyVGrid(columns: compactNavigationColumns, spacing: AppLayout.dashboardSpacing) {
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
                    VStack(alignment: .leading, spacing: 8) {
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
                            .controlSize(.regular)
                        }
                    }
                }
            }
            .padding(AppLayout.dashboardPadding)
            .frame(maxWidth: AppLayout.dashboardMaxWidth, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var refinementTile: some View {
        GlassTile {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refined Text with LLM")
                            .font(.system(size: 15, weight: .semibold))

                        Text(appState.refinementConfiguration.isEnabled ? "On" : "Off")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    Toggle("", isOn: refinementEnabledBinding)
                        .labelsHidden()
                        .toggleStyle(AppSwitchStyle())
                        .disabled(appState.whisperSettingsLocked)
                }

                Text(shortRefinementStatusText)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)

                if appState.refinementConfiguration.isEnabled {
                    HStack(spacing: 10) {
                        Button {
                            appState.prepareRefinementModel()
                        } label: {
                            Label("Prepare", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(appState.whisperSettingsLocked || !appState.isSelectedRefinementModelSupported)

                        Button {
                            appState.mainWindowPage = .settings
                        } label: {
                            Label("Settings", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                } else if !appState.hasPreparedRefinementModel {
                    HStack(spacing: 10) {
                        Button {
                            appState.mainWindowPage = .settings
                        } label: {
                            Label("Choose Model", systemImage: "list.bullet")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .tint(AppTheme.accent)

                        Text(appState.refinementModelMenuTitle(for: appState.refinementRecommendation.recommendedModel))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var recordingTile: some View {
        GlassTile {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.045))
                            .overlay(Circle().stroke(AppTheme.border, lineWidth: 0.75))

                        Image(systemName: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.recordingState.isRecording ? "Recording" : "Ready")
                            .font(.system(size: 17, weight: .semibold))

                        Text(appState.dictationSummaryText)
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 10)

                    WaveformBadge()
                        .frame(width: 38, height: 26)
                        .foregroundStyle(AppTheme.tertiaryText)
                }

                HStack {
                    Spacer(minLength: 0)

                    Button {
                        appState.toggleDictation()
                    } label: {
                        Label(appState.dictationActionTitle, systemImage: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(minWidth: 260, maxWidth: AppLayout.recordingButtonMaxWidth, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(AppTheme.accent)
                    .disabled(appState.transcriptionState.isBusy || appState.textInsertionState.isBusy)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var modelsPage: some View {
        DetailPage(title: "Models", systemImage: "cpu", back: goBackToDashboard) {
            VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                GlassTile {
                    VStack(alignment: .leading, spacing: 12) {
                        TileHeader(title: "Active Model", systemImage: "cpu")

                        HStack(alignment: .firstTextBaseline) {
                            Text(appState.whisperConfiguration.model.displayName)
                                .font(.system(size: 17, weight: .semibold))

                            Spacer()

                            Text(appState.whisperConfiguration.model.approximateDiskSizeDescription)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(AppTheme.accent)
                        }

                        Text(shortModelStatusText)
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }

                LazyVGrid(columns: dashboardColumns, spacing: AppLayout.sectionSpacing) {
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
                }

                modelStorageTile
            }
        }
    }

    private var modelStorageTile: some View {
        GlassTile {
            VStack(alignment: .leading, spacing: 12) {
                TileHeader(title: "Storage", systemImage: "externaldrive")

                Text(appState.modelStorageStatusText)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                let installedModelFiles = appState.installedLocalModelFiles

                if !installedModelFiles.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(installedModelFiles) { file in
                            ModelStorageRow(
                                file: file,
                                sizeText: appState.formattedLocalModelSize(file.byteCount),
                                isActive: appState.isActiveLocalModelFile(file)
                            )
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        prepareUnusedModelDeletionConfirmation()
                    } label: {
                        Label("Delete Unused Models...", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appState.canReviewUnusedModelDeletion)

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
            VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
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
                                Text(appState.refinementModelPickerTitle(for: model))
                                    .tag(model)
                                    .disabled(!appState.isRefinementModelSupported(model))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(appState.whisperSettingsLocked)

                        Text(appState.refinementModelDetailText(for: selectedRefinementModel))
                            .font(.system(size: 13))
                            .foregroundStyle(appState.isRefinementModelSupported(selectedRefinementModel) ? AppTheme.secondaryText : Color.orange.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(shortRefinementStatusText)
                            .font(.system(size: 13))
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
                            .disabled(appState.whisperSettingsLocked || !appState.isRefinementModelSupported(selectedRefinementModel))

                            Text("Local")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
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
            VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                GlassTile {
                    VStack(alignment: .leading, spacing: 12) {
                        TileHeader(title: "Last Transcript", systemImage: "text.bubble")

                        if let lastTranscription = appState.lastTranscription {
                            HStack {
                                Text(lastTranscription.taskMode.title)
                                    .font(.system(size: 15, weight: .semibold))

                                Spacer()

                                Text(lastTranscription.completedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppTheme.secondaryText)
                            }

                            if let refinement = lastTranscription.refinement {
                                Text(refinement.refinedText.isEmpty ? "Empty refined transcript" : refinement.refinedText)
                                    .font(.system(size: 15))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Divider()

                                Text("Raw Whisper Transcript")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.secondaryText)

                                Text(lastTranscription.text.isEmpty ? "Empty transcript" : lastTranscription.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(lastTranscription.text.isEmpty ? "Empty transcript" : lastTranscription.text)
                                .font(.system(size: 15))
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
                                .font(.system(size: 15))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }

                if let lastCapture = appState.lastCapture {
                    GlassTile {
                        VStack(alignment: .leading, spacing: 8) {
                            TileHeader(title: "Last Capture", systemImage: "waveform")

                            Text(lastCapture.durationText)
                                .font(.system(size: 15))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private var dashboardColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 285), spacing: AppLayout.sectionSpacing),
            GridItem(.flexible(minimum: 285), spacing: AppLayout.sectionSpacing)
        ]
    }

    private var compactNavigationColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 0), spacing: AppLayout.sectionSpacing),
            GridItem(.flexible(minimum: 0), spacing: AppLayout.sectionSpacing),
            GridItem(.flexible(minimum: 0), spacing: AppLayout.sectionSpacing)
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

    private var deleteUnusedModelsButtonTitle: String {
        let count = unusedModelDeletionCandidates.count
        return "Delete \(count) \(count == 1 ? "Model" : "Models")"
    }

    private var unusedModelDeletionConfirmationText: String {
        guard !unusedModelDeletionCandidates.isEmpty else {
            return "No unused local models are available to delete."
        }

        let itemText = unusedModelDeletionCandidates
            .map { file in
                "\(file.category.title): \(file.displayName) (\(appState.formattedLocalModelSize(file.byteCount)))"
            }
            .joined(separator: "\n")
        let byteCount = unusedModelDeletionCandidates.reduce(0) { $0 + $1.byteCount }

        return "This will permanently delete:\n\(itemText)\n\nEstimated space freed: \(appState.formattedLocalModelSize(byteCount)). Active models are kept."
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

    private func prepareUnusedModelDeletionConfirmation() {
        unusedModelDeletionCandidates = appState.unusedLocalModelFiles
        isShowingUnusedModelDeletionConfirmation = true
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

private enum AppLayout {
    static let windowMinWidth: CGFloat = 660
    static let windowMinHeight: CGFloat = 520
    static let contentMaxWidth: CGFloat = 620
    static let contentPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 12
    static let dashboardMaxWidth: CGFloat = 580
    static let dashboardPadding: CGFloat = 16
    static let dashboardSpacing: CGFloat = 10
    static let recordingButtonMaxWidth: CGFloat = 340
    static let tilePadding: CGFloat = 12
    static let tileCornerRadius: CGFloat = 8
}

private struct DetailPage<Content: View>: View {
    let title: String
    let systemImage: String
    let back: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                HStack(spacing: 10) {
                    Button(action: back) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Label(title, systemImage: systemImage)
                        .font(.system(size: 18, weight: .semibold))

                    Spacer()
                }

                content
            }
            .padding(AppLayout.contentPadding)
            .frame(maxWidth: AppLayout.contentMaxWidth, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct GlassTile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(AppLayout.tilePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous)
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
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AppTheme.secondaryText)
    }
}

private struct WaveformBadge: View {
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach([8, 16, 26, 20, 10], id: \.self) { height in
                Capsule(style: .continuous)
                    .frame(width: 3.5, height: CGFloat(height))
            }
        }
    }
}

private struct AppSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                configuration.isOn.toggle()
            }
        } label: {
            Capsule(style: .continuous)
                .fill(configuration.isOn ? Color.white.opacity(0.18) : Color.white.opacity(0.10))
                .frame(width: 42, height: 24)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.white : Color.white.opacity(0.42))
                        .frame(width: 18, height: 18)
                        .padding(3)
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
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))

                        Text(value)
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
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
                        .font(.system(size: 15, weight: .semibold))

                    Spacer()

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.accent)
                    }
                }

                Text(model.approximateDiskSizeDescription)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.accent)

                Text(model.detailText)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
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

private struct ModelStorageRow: View {
    let file: LocalModelFile
    let sizeText: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.category == .whisper ? "waveform" : "wand.and.sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text(file.category.title)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .labelStyle(.titleAndIcon)
            } else {
                Text("Unused")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.tertiaryText)
            }

            Text(sizeText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(minWidth: 74, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
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
                .frame(width: 20)

            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .medium))
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
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 20)

            Text(title)
                .font(.system(size: 16, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(minWidth: 74, alignment: .trailing)
        }
    }
}
