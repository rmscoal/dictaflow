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
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(AppTheme.border)
                .frame(width: 1)

            selectedPage
        }
        .frame(minWidth: AppLayout.windowMinWidth, minHeight: AppLayout.windowMinHeight)
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(MainWindowPage.allCases) { page in
                        Button {
                            appState.mainWindowPage = page
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: page.systemImage)
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 16)

                                Text(page.title)
                                    .font(.system(size: 13, weight: .medium))

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(page == appState.mainWindowPage ? AppTheme.primaryText : AppTheme.secondaryText)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(page == appState.mainWindowPage ? AppTheme.controlFill : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(page == appState.mainWindowPage ? AppTheme.border : Color.clear, lineWidth: 0.75)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
            .scrollContentBackground(.hidden)

            Divider()
                .overlay(AppTheme.border)

            HStack(spacing: 8) {
                Link(destination: URL(string: "https://github.com/rmscoal/dictaflow")!) {
                    Image("GitHubMark")
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("View DictaFlow on GitHub")

                Text("v\(appVersion)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.tertiaryText)

                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
        }
        .background(AppTheme.sidebar)
        .frame(width: AppLayout.sidebarWidth)
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch appState.mainWindowPage {
        case .dictation:
            dictationPage
        case .models:
            modelsPage
        case .refinement:
            refinementPage
        case .latestResult:
            latestResultPage
        case .privacyAccess:
            privacyPage
        }
    }

    private var dictationPage: some View {
        SettingsPage(title: "Dictation") {
            SettingsSection(title: "Transcription") {
                SettingsRow(title: "Task") {
                    Picker("Task", selection: taskModeBinding) {
                        ForEach(WhisperTaskMode.allCases, id: \.self) { taskMode in
                            Text(taskMode.title).tag(taskMode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: AppLayout.controlWidth)
                    .disabled(appState.whisperSettingsLocked)
                }

                SettingsRow(
                    title: "Input language"
                ) {
                    Picker("Input Language", selection: inputLanguageBinding) {
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
                    .frame(width: AppLayout.controlWidth, alignment: .trailing)
                    .disabled(appState.whisperSettingsLocked)
                }
            }

            SettingsSection(title: "Trigger") {
                SettingsRow(
                    title: "Recording shortcut",
                    detail: "Global shortcut"
                ) {
                    Text(appState.hotkeyDisplayText)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                }
            }

            SettingsSection(title: "Defaults") {
                SettingsRow(
                    title: "Restore defaults"
                ) {
                    Button("Restore Defaults") {
                        appState.resetWhisperSettingsToDefaults()
                        selectedModel = WhisperConfiguration.default.model
                        selectedRefinementModel = RefinementConfiguration.default.model
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.whisperSettingsLocked)
                }
            }
        }
    }

    private var modelsPage: some View {
        SettingsPage(title: "Models") {
            SettingsSection(title: "Whisper") {
                SettingsRow(title: "Transcription model") {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(WhisperModelDescriptor.allCases, id: \.self) { model in
                            Text("\(model.displayName) (\(model.approximateDiskSizeDescription))")
                                .tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: AppLayout.controlWidth, alignment: .trailing)
                    .disabled(appState.whisperSettingsLocked)
                }

                SettingsRow(
                    title: "Prepare model",
                    detail: selectedModel == appState.whisperConfiguration.model
                        ? "Active and ready for local transcription"
                        : "Download and make this the active model"
                ) {
                    Button {
                        if selectedModel == appState.whisperConfiguration.model {
                            appState.retryModelPreparation()
                        } else {
                            isShowingModelPreparationConfirmation = true
                        }
                    } label: {
                        Label(
                            selectedModel == appState.whisperConfiguration.model ? "Prepare Again" : "Use Model",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.whisperSettingsLocked)
                }
            }

            SettingsSection(title: "Local Storage") {
                SettingsRow(title: "Models folder", detail: appState.modelStorageStatusText) {
                    Button("Open Folder") {
                        appState.openModelsFolder()
                    }
                    .buttonStyle(.bordered)
                }

                if appState.installedLocalModelFiles.isEmpty {
                    Text("No local model files are stored yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    ForEach(appState.installedLocalModelFiles) { file in
                        ModelFileRow(
                            file: file,
                            size: appState.formattedLocalModelSize(file.byteCount),
                            isActive: appState.isActiveLocalModelFile(file)
                        )
                    }
                }

                SettingsRow(title: "Cleanup", detail: "Remove downloaded models that are not in use") {
                    Button("Delete Unused…") {
                        prepareUnusedModelDeletionConfirmation()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appState.canReviewUnusedModelDeletion)
                }
            }
        }
    }

    private var refinementPage: some View {
        SettingsPage(title: "Refinement") {
            SettingsSection(title: "Local Cleanup") {
                SettingsRow(
                    title: "Refine transcript",
                    detail: "Clean transcripts locally before insertion"
                ) {
                    Toggle("", isOn: refinementEnabledBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(appState.whisperSettingsLocked)
                }

                SettingsRow(
                    title: "Refinement model",
                    detail: "Runs privately on this Mac"
                ) {
                    Picker("Model", selection: refinementModelBinding) {
                        ForEach(RefinementModelDescriptor.allCases, id: \.self) { model in
                            Text(appState.refinementModelMenuTitle(for: model))
                                .tag(model)
                                .disabled(!appState.isRefinementModelSupported(model))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: AppLayout.controlWidth, alignment: .trailing)
                    .disabled(appState.whisperSettingsLocked)
                }

                SettingsRow(title: "Prepare model", detail: "Download and make this the active model") {
                    Button {
                        appState.prepareAndUseRefinementModel(selectedRefinementModel)
                    } label: {
                        Label("Use & Prepare", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        appState.whisperSettingsLocked ||
                        !appState.isRefinementRuntimeAvailable ||
                        !appState.isRefinementModelSupported(selectedRefinementModel)
                    )
                }

                SettingsRow(
                    title: "Status",
                    detail: appState.refinementConfiguration.isEnabled
                        ? "Runs locally before insertion"
                        : "Off; raw Whisper text is inserted"
                ) {
                    if appState.isRefinementServerPreparing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        StatusValue(
                            text: appState.refinementConfiguration.isEnabled ? "On" : "Off",
                            isPositive: appState.refinementConfiguration.isEnabled
                        )
                    }
                }
            }

            SettingsSection(title: "System Prompt") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Instructions")
                            .font(.system(size: 13, weight: .medium))

                        Text("Use \(RefinementPromptTemplate.languageInstructionPlaceholder) where the transcription instruction should appear")
                            .font(.system(size: 11.5))
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    TextEditor(text: refinementPromptTextBinding)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(7)
                        .frame(height: 150)
                        .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(AppTheme.border, lineWidth: 1)
                        }
                        .disabled(appState.whisperSettingsLocked)
                }

                SettingsRow(title: "Prompt file", detail: appState.refinementPromptStorageText) {
                    HStack(spacing: 8) {
                        Button("Save") {
                            appState.saveRefinementPromptText()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            appState.whisperSettingsLocked ||
                            !appState.isRefinementPromptDirty ||
                            appState.refinementPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )

                        Button("Reset") {
                            appState.resetActiveRefinementPrompt()
                        }
                        .buttonStyle(.bordered)
                        .disabled(appState.whisperSettingsLocked)

                        Button {
                            appState.openRefinementPromptsFolder()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.bordered)
                        .help("Open Prompts Folder")
                    }
                }
            }
        }
    }

    private var latestResultPage: some View {
        SettingsPage(title: "Latest Result") {
            SettingsSection(title: "Transcription") {
                if let transcription = appState.lastTranscription {
                    SettingsRow(title: "Task", detail: "Completed \(transcription.completedAt.formatted(date: .abbreviated, time: .shortened))") {
                        Text(transcription.taskMode.title)
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    SettingsRow(title: "Detected language") {
                        Text(transcription.detectedLanguageDisplayName)
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    TranscriptBlock(
                        title: "Whisper original",
                        text: transcription.text.isEmpty ? "Empty transcript" : transcription.text
                    )

                    TranscriptBlock(
                        title: "Insertion text",
                        text: refinementOutputText(for: transcription)
                    )

                    SettingsRow(
                        title: refinementStatusTitle(for: transcription),
                        detail: refinementStatusDetail(for: transcription)
                    ) {
                        StatusValue(
                            text: transcription.refinement == nil ? "Raw" : "Refined",
                            isPositive: transcription.refinement != nil
                        )
                    }

                    SettingsRow(title: "Actions") {
                        HStack(spacing: 8) {
                            Button("Insert Again") {
                                appState.insertLastTranscription()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!appState.canInsertLastTranscription)

                            Button("Copy") {
                                appState.copyLastTranscription()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!appState.canCopyLastTranscription)
                        }
                    }
                } else {
                    SettingsRow(
                        title: "No result yet",
                        detail: "Your latest local transcription will appear here"
                    ) {
                        Button("Start Recording") {
                            appState.toggleDictation()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            if let capture = appState.lastCapture {
                SettingsSection(title: "Capture") {
                    SettingsRow(title: "Recording duration") {
                        Text(capture.durationText)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }
        }
    }

    private var privacyPage: some View {
        SettingsPage(title: "Privacy & Access") {
            SettingsSection(title: "Permissions") {
                permissionRow(
                    title: "Microphone",
                    detail: appState.microphonePermissionState.detailText,
                    value: appState.microphonePermissionState.title,
                    isGranted: appState.microphonePermissionState == .granted
                ) {
                    appState.refreshMicrophonePermissionStatus()
                }

                SettingsRow(
                    title: "Accessibility",
                    detail: appState.accessibilityPermissionState.detailText
                ) {
                    HStack(spacing: 8) {
                        StatusValue(
                            text: appState.accessibilityPermissionState.title,
                            isPositive: appState.accessibilityPermissionState == .granted
                        )

                        Button("Open Settings") {
                            appState.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsSection(title: "Local Data") {
                SettingsRow(
                    title: "Recordings",
                    detail: "Temporary local .m4a files are removed after processing"
                ) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(AppTheme.secondaryText)
                }

                SettingsRow(
                    title: "Models",
                    detail: "Stored in Application Support and never uploaded"
                ) {
                    Button("Open Folder") {
                        appState.openModelsFolder()
                    }
                    .buttonStyle(.bordered)
                }

                SettingsRow(
                    title: "Text insertion",
                    detail: appState.textInsertionStatusText
                ) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        value: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SettingsRow(title: title, detail: detail) {
            HStack(spacing: 8) {
                StatusValue(text: value, isPositive: isGranted)

                Button("Refresh", action: action)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
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

    private var refinementPromptTextBinding: Binding<String> {
        Binding(
            get: { appState.refinementPromptText },
            set: { appState.updateRefinementPromptText($0) }
        )
    }

    private func prepareUnusedModelDeletionConfirmation() {
        unusedModelDeletionCandidates = appState.unusedLocalModelFiles
        isShowingUnusedModelDeletionConfirmation = true
    }

    private func refinementStatusTitle(for transcription: WhisperTranscriptionResult) -> String {
        switch transcription.refinementStatus {
        case .disabled:
            return "Local refinement off"
        case .skipped:
            return "Local refinement skipped"
        case .succeeded(let model, _, _):
            return "Refined with \(model.displayName)"
        case .failed(let model, _, _):
            return "Refinement failed with \(model.displayName)"
        }
    }

    private func refinementStatusDetail(for transcription: WhisperTranscriptionResult) -> String {
        switch transcription.refinementStatus {
        case .disabled:
            return "The raw Whisper transcript was used."
        case .skipped(let reason):
            return reason
        case .succeeded(_, let mode, let completedAt):
            return "\(mode.title) completed locally at \(completedAt.formatted(date: .omitted, time: .shortened))."
        case .failed(_, let message, _):
            return "Raw Whisper text was used instead. \(message)"
        }
    }

    private func refinementOutputText(for transcription: WhisperTranscriptionResult) -> String {
        if let refinement = transcription.refinement {
            return refinement.refinedText.isEmpty ? "Empty refined transcript" : refinement.refinedText
        }

        switch transcription.refinementStatus {
        case .disabled:
            return transcription.text.isEmpty ? "Empty transcript" : transcription.text
        case .skipped:
            return "No refined output. DictaFlow used the raw Whisper transcript."
        case .failed:
            return "Refinement failed. DictaFlow used the raw Whisper transcript."
        case .succeeded:
            return "Empty refined transcript"
        }
    }
}

private enum AppTheme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.060)
    static let sidebar = Color(red: 0.075, green: 0.075, blue: 0.082)
    static let controlFill = Color.white.opacity(0.055)
    static let accent = Color.white.opacity(0.92)
    static let border = Color.white.opacity(0.09)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)
}

private enum AppLayout {
    static let windowMinWidth: CGFloat = 700
    static let windowMinHeight: CGFloat = 480
    static let sidebarWidth: CGFloat = 190
    static let contentMaxWidth: CGFloat = 760
    static let contentPadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 26
    static let rowSpacing: CGFloat = 18
    static let labelWidth: CGFloat = 190
    static let controlWidth: CGFloat = 295
}

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                Text(title)
                    .font(.system(size: 23, weight: .semibold))
                    .padding(.bottom, 2)

                content
            }
            .padding(AppLayout.contentPadding)
            .frame(maxWidth: AppLayout.contentMaxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(AppTheme.tertiaryText)

                Rectangle()
                    .fill(AppTheme.border)
                    .frame(height: 1)
            }

            VStack(alignment: .leading, spacing: AppLayout.rowSpacing) {
                content
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: AppLayout.labelWidth, alignment: .leading)

            Spacer(minLength: 0)

            control
                .controlSize(.regular)
                .frame(width: AppLayout.controlWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusValue: View {
    let text: String
    let isPositive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isPositive ? AppTheme.primaryText : AppTheme.tertiaryText)
                .frame(width: 5, height: 5)

            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(isPositive ? AppTheme.primaryText : AppTheme.secondaryText)
    }
}

private struct ModelFileRow: View {
    let file: LocalModelFile
    let size: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.system(size: 13, weight: .medium))

                Text(file.category.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer()

            if isActive {
                StatusValue(text: "Active", isPositive: true)
            }

            Text(size)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 72, alignment: .trailing)
        }
    }
}

private struct TranscriptBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)

            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
