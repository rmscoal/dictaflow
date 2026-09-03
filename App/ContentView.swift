import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: DictaFlowAppState
    @State private var isShowingHelp = false
    @State private var isSidebarCollapsed = false
    @State private var isShowingModelPreparationConfirmation = false
    @State private var isShowingRefinementModelPreparationConfirmation = false
    @State private var isShowingRefinementModelDeletionConfirmation = false
    @State private var isShowingUnusedModelDeletionConfirmation = false
    @State private var selectedModel: WhisperModelDescriptor
    @State private var selectedRefinementModel: RefinementModelDescriptor
    @State private var refinementModelPendingDeletion: RefinementModelDescriptor?
    @State private var unusedModelDeletionCandidates: [LocalModelFile] = []

    init(appState: DictaFlowAppState) {
        self.appState = appState
        _selectedModel = State(initialValue: appState.whisperConfiguration.model)
        _selectedRefinementModel = State(initialValue: appState.refinementConfiguration.model)
        _refinementModelPendingDeletion = State(initialValue: nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            VStack(spacing: 0) {
                pageHeader
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(AppTheme.background)
        }
        .frame(minWidth: AppLayout.windowMinWidth, minHeight: AppLayout.windowMinHeight)
        .foregroundStyle(AppTheme.primaryText)
        .alert(
            "Download \(selectedModel.displayName) Model?",
            isPresented: $isShowingModelPreparationConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Download Model") {
                appState.prepareAndUseModel(selectedModel)
            }
        } message: {
            Text("DictaFlow will download \(selectedModel.displayName) locally and use it for future recordings.")
        }
        .alert(
            "Download \(selectedRefinementModel.displayName) Model?",
            isPresented: $isShowingRefinementModelPreparationConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Download Model") {
                appState.prepareAndUseRefinementModel(selectedRefinementModel)
            }
        } message: {
            Text("DictaFlow will download \(selectedRefinementModel.displayName) locally and use it for text refinement.")
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
        .alert(
            "Delete \(refinementModelPendingDeletion?.displayName ?? "Refinement Model")?",
            isPresented: $isShowingRefinementModelDeletionConfirmation
        ) {
            Button("Cancel", role: .cancel) {
                refinementModelPendingDeletion = nil
            }
            Button("Delete Model", role: .destructive) {
                if let model = refinementModelPendingDeletion {
                    appState.deleteRefinementModel(model)
                }
                refinementModelPendingDeletion = nil
            }
        } message: {
            Text("This permanently deletes the local model file. If it is active, DictaFlow will use another downloaded refinement model when available. Otherwise, text refinement will turn off.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.mainWindowPage {
        case .overview:
            overviewPage
        case .dictation:
            dictationPage
        case .refinement:
            refinementPage
        case .history:
            historyPage
        case .shortcutAndAudio:
            shortcutAndAudioPage
        case .models:
            modelsPage
        case .permissions:
            permissionsPage
        case .updates:
            updatesPage
        }
    }

    private var sidebar: some View {
        VStack(alignment: isSidebarCollapsed ? .center : .leading, spacing: 0) {
            Group {
                if isSidebarCollapsed {
                    CollapsedSidebarLogoButton {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSidebarCollapsed = false
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        DictaFlowLogo()

                        Spacer(minLength: 0)

                        SidebarCollapseButton {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isSidebarCollapsed = true
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 23)
            .frame(maxWidth: .infinity)

            SidebarSection(title: "DICTAFLOW", isCollapsed: isSidebarCollapsed) {
                SidebarItem(page: .overview, title: "Overview", systemImage: "square.grid.2x2.fill", isCollapsed: isSidebarCollapsed, selection: mainWindowPageBinding)
                SidebarItem(page: .dictation, title: "Dictation", systemImage: "waveform", isCollapsed: isSidebarCollapsed, selection: mainWindowPageBinding)
                SidebarItem(page: .refinement, title: "Refinement", systemImage: "wand.and.sparkles", isCollapsed: isSidebarCollapsed, selection: mainWindowPageBinding)
                SidebarItem(page: .history, title: "History", systemImage: "clock", isCollapsed: isSidebarCollapsed, selection: mainWindowPageBinding)
            }

            Divider().overlay(AppTheme.sidebarBorder).padding(.vertical, 13)

            SidebarSection(title: "CONFIGURATION", isCollapsed: isSidebarCollapsed) {
                SidebarItem(page: .shortcutAndAudio, title: "Shortcut & Audio", systemImage: "keyboard", isCollapsed: isSidebarCollapsed, selection: mainWindowPageBinding)
                SidebarItem(page: .models, title: "Models", systemImage: "cpu", isCollapsed: isSidebarCollapsed, selection: mainWindowPageBinding)
                SidebarItem(page: .permissions, title: "Permissions", systemImage: "lock.shield", isCollapsed: isSidebarCollapsed, selection: mainWindowPageBinding)
                SidebarItem(page: .updates, title: "Updates", systemImage: "arrow.triangle.2.circlepath", isCollapsed: isSidebarCollapsed, selection: mainWindowPageBinding)
            }

            Spacer(minLength: 12)
        }
        .frame(
            minWidth: isSidebarCollapsed ? AppLayout.collapsedSidebarWidth : AppLayout.sidebarWidth,
            idealWidth: isSidebarCollapsed ? AppLayout.collapsedSidebarWidth : AppLayout.sidebarWidth,
            maxWidth: isSidebarCollapsed ? AppLayout.collapsedSidebarWidth : AppLayout.sidebarWidth
        )
        .background(AppTheme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppTheme.sidebarBorder).frame(width: 1)
        }
    }

    private var pageHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pageTitle)
                    .font(.system(size: 23, weight: .semibold))

                Text(pageSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                isShowingHelp.toggle()
            } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(AppTheme.controlFill, in: Circle())
            .overlay(Circle().stroke(AppTheme.border, lineWidth: 1))
            .help("Help")
            .popover(isPresented: $isShowingHelp, arrowEdge: .top) {
                HelpPopover(selection: mainWindowPageBinding, isPresented: $isShowingHelp)
            }
        }
        .padding(.horizontal, AppLayout.contentPadding)
        .frame(height: AppLayout.headerHeight)
        .background(AppTheme.barFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.border).frame(height: 1)
        }
    }

    private var overviewPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                overviewRecordingTile

                HStack(spacing: 10) {
                    OverviewFeatureCard(
                        title: "Whisper Model",
                        badge: overviewWhisperModelBadge,
                        systemImage: "cpu",
                        primaryText: Text(appState.whisperConfiguration.model.displayName).fontWeight(.semibold)
                            + Text(" · Multilingual"),
                        secondaryText: "Fast local transcription · \(appState.whisperConfiguration.model.approximateDiskSizeDescription)"
                    ) {
                        appState.mainWindowPage = .models
                    }

                    OverviewFeatureCard(
                        title: "Text Refinement",
                        badge: appState.refinementConfiguration.isEnabled ? "ON" : "OFF",
                        systemImage: "wand.and.sparkles",
                        primaryText: Text(appState.refinementConfiguration.model.displayName).fontWeight(.semibold),
                        secondaryText: "Cleans punctuation and wording locally."
                    ) {
                        appState.mainWindowPage = .refinement
                    }
                }

                GlassTile {
                    VStack(alignment: .leading, spacing: 0) {
                        StatusNavigationLine(title: "Microphone", value: appState.microphonePermissionState.title, systemImage: "mic.fill") {
                            appState.mainWindowPage = .permissions
                        }
                        Divider().overlay(AppTheme.border)
                        StatusNavigationLine(title: "Accessibility", value: appState.accessibilityPermissionState.title, systemImage: "figure.wave.circle") {
                            appState.mainWindowPage = .permissions
                        }
                        Divider().overlay(AppTheme.border)
                        StatusNavigationLine(title: "Last transcript", value: historySummaryText, systemImage: "text.bubble") {
                            appState.mainWindowPage = .history
                        }
                    }
                }
            }
            .padding(.horizontal, AppLayout.contentPadding)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
    }

    private var overviewRecordingTile: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("DICTATION")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.72)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.bottom, 6)

                Text(appState.recordingState.isRecording ? "Listening…" : "Speak naturally.")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.45)

                Text(overviewRecordingDetailText)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
                    .padding(.bottom, 14)

                Button {
                    appState.toggleDictation()
                } label: {
                    Text("\(appState.recordingState.isRecording ? "Stop Recording" : "Start Dictation")  ·  \(appState.hotkeyDisplayText)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 13)
                        .frame(minWidth: 142, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: AppTheme.accent.opacity(0.28), radius: 8, x: 0, y: 5)
                .disabled(appState.isEditingGlobalShortcut || appState.transcriptionState.isBusy || appState.textInsertionState.isBusy)
            }
            .padding(.leading, 19)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .fill(AppTheme.accent.opacity(0.07))
                    .frame(width: 118, height: 118)
                    .blur(radius: 12)

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.accent)
                    .frame(width: 54, height: 54)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
                    .shadow(color: AppTheme.accent.opacity(0.18), radius: 12, x: 0, y: 8)

                Image(systemName: appState.recordingState.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 122)
        }
        .frame(maxWidth: .infinity, minHeight: 152)
        .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var modelsPage: some View {
        DetailPage {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    ModelPageSectionHeader(
                        title: "Whisper models",
                        subtitle: "Local speech recognition and translation"
                    )

                    EqualHeightModelGrid(spacing: AppLayout.sectionSpacing) {
                        ForEach(WhisperModelDescriptor.allCases, id: \.self) { model in
                            let isPrepared = appState.isWhisperModelPrepared(model)
                            let isActive = model == appState.whisperConfiguration.model && isPrepared

                            ModelChoiceCard(
                                name: model.displayName,
                                sizeText: model.approximateDiskSizeDescription,
                                detailText: model.detailText,
                                isActive: isActive,
                                needsPreparation: !isPrepared,
                                isUnavailable: false,
                                isInteractionLocked: appState.whisperSettingsLocked,
                                deleteAction: nil
                            ) {
                                selectedModel = model
                                if !isPrepared {
                                    isShowingModelPreparationConfirmation = true
                                } else if !isActive {
                                    appState.updateWhisperModel(model)
                                }
                            }
                        }
                    }

                    if isWhisperModelPreparationActive || appState.whisperModelPreparationFailed {
                        ModelDownloadStatusPanel(
                            title: whisperModelDownloadStatusTitle,
                            statusText: appState.whisperModelPreparationStatusText,
                            isActive: isWhisperModelPreparationActive,
                            progress: whisperModelPreparationProgress,
                            hasFailed: appState.whisperModelPreparationFailed
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ModelPageSectionHeader(
                        title: "Text refinement models",
                        subtitle: "Local cleanup for punctuation and wording"
                    )

                    EqualHeightModelGrid(spacing: AppLayout.sectionSpacing) {
                        ForEach(RefinementModelDescriptor.allCases, id: \.self) { model in
                            let isPrepared = appState.isRefinementModelPrepared(model)
                            let isActive = model == appState.refinementConfiguration.model && isPrepared

                            ModelChoiceCard(
                                name: model.displayName,
                                sizeText: "\(model.approximateDiskSizeDescription) · \(model.estimatedRuntimeMemoryDescription)",
                                detailText: appState.refinementModelDetailText(for: model),
                                isActive: isActive,
                                needsPreparation: !isPrepared,
                                isUnavailable: !appState.isRefinementModelSupported(model),
                                isInteractionLocked: appState.whisperSettingsLocked,
                                deleteAction: isPrepared ? {
                                    refinementModelPendingDeletion = model
                                    isShowingRefinementModelDeletionConfirmation = true
                                } : nil
                            ) {
                                selectedRefinementModel = model
                                if !isPrepared {
                                    isShowingRefinementModelPreparationConfirmation = true
                                } else if !isActive {
                                    appState.updateRefinementModel(model)
                                }
                            }
                        }
                    }

                    if isRefinementModelPreparationActive || appState.refinementModelPreparationFailed {
                        ModelDownloadStatusPanel(
                            title: refinementModelDownloadStatusTitle,
                            statusText: appState.refinementModelPreparationStatusText,
                            isActive: isRefinementModelPreparationActive,
                            progress: refinementModelPreparationProgress,
                            hasFailed: appState.refinementModelPreparationFailed
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ModelPageSectionHeader(
                        title: "Storage",
                        subtitle: "Installed model files and disk usage"
                    )

                    modelStorageTile
                }
            }
        }
    }

    private var modelStorageTile: some View {
        GlassTile {
            VStack(alignment: .leading, spacing: 12) {
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
                    Spacer(minLength: 0)

                    Button {
                        appState.openModelsFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        prepareUnusedModelDeletionConfirmation()
                    } label: {
                        Label("Delete Unused Models", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.destructive)
                    .disabled(!appState.canReviewUnusedModelDeletion)
                }
            }
        }
    }

    private var shortcutAndAudioPage: some View {
        DetailPage {
            VStack(alignment: .leading, spacing: 7) {
                FormSectionTitle("Global shortcut")

                SettingsFormPanel {
                    SettingsFormRow(
                        title: "Start or stop dictation",
                        detail: appState.isEditingGlobalShortcut ? "Press a shortcut with at least one modifier" : "Works from any app"
                    ) {
                        if appState.isEditingGlobalShortcut {
                            ZStack {
                                Text("Press shortcut…")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AppTheme.secondaryText)

                                GlobalShortcutCaptureView(
                                    isCapturing: true,
                                    onShortcut: { appState.handleGlobalShortcutCandidate($0) },
                                    onCancel: { appState.cancelGlobalShortcutEditing() }
                                )
                                .opacity(0.01)
                                .accessibilityHidden(true)
                            }
                            .frame(width: 142, height: 28)
                            .background(AppTheme.editorFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(AppTheme.accent.opacity(0.65), lineWidth: 1)
                            )
                        } else {
                            Button(appState.hotkeyDisplayText) {
                                appState.beginGlobalShortcutEditing()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(width: 142, alignment: .trailing)
                            .disabled(appState.whisperSettingsLocked)
                        }
                    }

                    if appState.isEditingGlobalShortcut {
                        Divider().overlay(AppTheme.border)

                        HStack(spacing: 10) {
                            Text(appState.globalShortcutEditingMessage ?? "Escape cancels without changing the shortcut.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(appState.globalShortcutEditingMessage == nil ? AppTheme.secondaryText : Color.orange.opacity(0.9))

                            Spacer(minLength: 8)

                            Button("Cancel", role: .cancel) {
                                appState.cancelGlobalShortcutEditing()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 13)
                        .frame(minHeight: 38)
                    }
                }

                FormSectionTitle("During recording")
                    .padding(.top, 7)

                SettingsFormPanel {
                    SettingsFormRow(
                        title: "System audio",
                        detail: "Choose how other audio behaves while recording"
                    ) {
                        Picker("System audio", selection: recordingPlaybackBehaviorBinding) {
                            Text("Unchanged").tag(RecordingPlaybackBehavior.unchanged)
                            Text("Lower").tag(RecordingPlaybackBehavior.lowerSystemVolume)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 166)
                        .disabled(appState.whisperSettingsLocked)
                    }

                    Divider().overlay(AppTheme.border)

                    SettingsFormRow(
                        title: "Pause supported apps",
                        detail: "Resume playback after recording"
                    ) {
                        Text("COMING SOON")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(AppTheme.accent.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .opacity(0.72)
                }
            }
        }
    }

    private var dictationPage: some View {
        DetailPage {
            VStack(alignment: .leading, spacing: 7) {
                FormSectionTitle("Transcription defaults")

                SettingsFormPanel {
                    SettingsFormRow(
                        title: "Task",
                        detail: "Transcribe speech or translate it to English"
                    ) {
                        Picker("Task", selection: taskModeBinding) {
                            Text("Transcribe").tag(WhisperTaskMode.transcribe)
                            Text("Translate").tag(WhisperTaskMode.translateToEnglish)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 166)
                        .disabled(appState.whisperSettingsLocked)
                    }

                    Divider().overlay(AppTheme.border)

                    SettingsFormRow(
                        title: "Input language",
                        detail: "Automatic works well for mixed-language speech"
                    ) {
                        Picker("Input language", selection: inputLanguageBinding) {
                            Text(WhisperInputLanguage.automatic.displayName).tag(WhisperInputLanguage.automatic)
                            if !appState.commonWhisperLanguages.isEmpty {
                                Divider()
                                Section("Common") {
                                    ForEach(appState.commonWhisperLanguages) { language in
                                        Text(language.displayName).tag(language.inputLanguage)
                                    }
                                }
                            }
                            Section("All") {
                                ForEach(appState.additionalWhisperLanguages) { language in
                                    Text(language.displayName).tag(language.inputLanguage)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 142)
                        .disabled(appState.whisperSettingsLocked)
                    }

                    Divider().overlay(AppTheme.border)

                    SettingsFormRow(
                        title: "Whisper model",
                        detail: "Only prepared local models can be selected"
                    ) {
                        WhisperModelPickerControl(
                            selectedModel: appState.whisperConfiguration.model,
                            isEnabled: !appState.whisperSettingsLocked,
                            isModelSelectable: { appState.isWhisperModelPrepared($0) },
                            selectModel: { appState.updateWhisperModel($0) }
                        )
                    }
                }
            }
        }
    }

    private var refinementPage: some View {
        DetailPage {
            VStack(alignment: .leading, spacing: 7) {
                FormSectionTitle("Local text cleanup")

                SettingsFormPanel {
                    SettingsFormRow(
                        title: "Refine before insertion",
                        detail: "Clean punctuation and wording with a local LLM"
                    ) {
                        Toggle("Refine before insertion", isOn: refinementEnabledBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(appState.whisperSettingsLocked)
                    }

                    Divider().overlay(AppTheme.border)

                    SettingsFormRow(
                        title: "Refinement model",
                        detail: "Only prepared local models can be selected"
                    ) {
                        RefinementModelPickerControl(
                            selectedModel: appState.isSelectedRefinementModelPrepared
                                ? appState.refinementConfiguration.model
                                : nil,
                            emptySelectionTitle: RefinementModelDescriptor.allCases.contains {
                                appState.isRefinementModelSupported($0) && appState.isRefinementModelPrepared($0)
                            } ? "Select a model" : "No model available",
                            isEnabled: !appState.whisperSettingsLocked && appState.isRefinementRuntimeAvailable,
                            isModelSelectable: {
                                appState.isRefinementModelSupported($0) && appState.isRefinementModelPrepared($0)
                            },
                            selectModel: { appState.updateRefinementModel($0) }
                        )
                    }
                }

                FormSectionTitle("System prompt")
                    .padding(.top, 7)

                TextEditor(text: refinementPromptTextBinding)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AppTheme.primaryText.opacity(0.86))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 116)
                    .padding(9)
                    .background(AppTheme.editorFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
                    .disabled(appState.whisperSettingsLocked)

                HStack(spacing: 8) {
                    Text(shortRefinementStatusText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppTheme.tertiaryText)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Button("Folder") { appState.openRefinementPromptsFolder() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button("Reset") { appState.resetActiveRefinementPrompt() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appState.whisperSettingsLocked)

                    Button("Save") { appState.saveRefinementPromptText() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                        .disabled(appState.whisperSettingsLocked || !appState.isRefinementPromptDirty || appState.refinementPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var permissionsPage: some View {
        DetailPage {
            VStack(alignment: .leading, spacing: 7) {
                FormSectionTitle("Required access")

                SettingsFormPanel {
                    SettingsFormRow(
                        title: "Microphone",
                        detail: "Required to record speech"
                    ) {
                        PermissionStatusControl(
                            title: appState.microphonePermissionState.title,
                            isAllowed: appState.microphonePermissionState == .granted,
                            showsSettingsButton: appState.microphonePermissionState == .denied,
                            openSettings: { appState.openMicrophoneSettings() }
                        )
                    }

                    Divider().overlay(AppTheme.border)

                    SettingsFormRow(
                        title: "Accessibility",
                        detail: "Used only to insert text into the active app"
                    ) {
                        PermissionStatusControl(
                            title: appState.accessibilityPermissionState.title,
                            isAllowed: appState.accessibilityPermissionState == .granted,
                            showsSettingsButton: appState.accessibilityPermissionState == .denied,
                            openSettings: { appState.openAccessibilitySettings() }
                        )
                    }
                }
            }
        }
    }

    private var updatesPage: some View {
        DetailPage {
            VStack(alignment: .leading, spacing: 7) {
                FormSectionTitle(appState.appDisplayNameText)

                SettingsFormPanel {
                    SettingsFormRow(
                        title: "Version \(appState.appVersionText)",
                        detail: appState.appDisplayNameText.hasSuffix("Dev")
                            ? "You are using the development build"
                            : "You are using the release build"
                    ) {
                        if let availableUpdate = appState.availableUpdate {
                            Button("View \(availableUpdate.version.displayString)") {
                                appState.openAvailableUpdate()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(AppTheme.accent)
                        } else {
                            Button(appState.isCheckingForUpdates ? "Checking…" : "Check Now") {
                                appState.checkForUpdates()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(appState.isCheckingForUpdates)
                        }
                    }

                    Divider().overlay(AppTheme.border)

                    SettingsFormRow(
                        title: "Automatic update checks",
                        detail: "Contacts GitHub at most once per day"
                    ) {
                        Toggle("Automatic update checks", isOn: automaticUpdateChecksBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }

                Text(appState.updateStatusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var historyPage: some View {
        DetailPage {
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

                            RefinementStatusBadge(
                                title: refinementStatusTitle(for: lastTranscription),
                                detail: refinementStatusDetail(for: lastTranscription),
                                color: refinementStatusColor(for: lastTranscription)
                            )

                            TranscriptTextBlock(
                                title: "Whisper Original",
                                text: lastTranscription.text.isEmpty ? "Empty transcript" : lastTranscription.text,
                                prominence: .primary
                            )

                            TranscriptTextBlock(
                                title: "LLM Refinement Result",
                                text: refinementOutputText(for: lastTranscription),
                                prominence: lastTranscription.refinement == nil ? .secondary : .primary
                            )

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

    private var pageTitle: String {
        switch appState.mainWindowPage {
        case .overview: "Overview"
        case .dictation: "Dictation"
        case .refinement: "Refinement"
        case .history: "History"
        case .shortcutAndAudio: "Shortcut & Audio"
        case .models: "Models"
        case .permissions: "Permissions"
        case .updates: "Updates"
        }
    }

    private var pageSubtitle: String {
        switch appState.mainWindowPage {
        case .overview: "Ready for private, local dictation"
        case .dictation: "Choose how speech becomes text."
        case .refinement: "Clean transcripts locally before insertion."
        case .history: "Review and reuse your latest transcript."
        case .shortcutAndAudio: "Control recording access and audio behavior."
        case .models: "Manage local Whisper models and storage."
        case .permissions: "Check the system access DictaFlow needs."
        case .updates: "Version and update preferences."
        }
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

    private var overviewRecordingDetailText: String {
        if appState.recordingState.isRecording {
            return "Your audio is being captured locally. Press the shortcut again when you are finished."
        }

        return "DictaFlow transcribes on this Mac, refines the text locally, then inserts it into your active app."
    }

    private var shortRefinementStatusText: String {
        appState.refinementStatusText.replacingOccurrences(of: appState.modelsDirectoryPath, with: "local cache")
    }

    private var overviewWhisperModelBadge: String {
        let activeModelIdentifier = appState.whisperConfiguration.model.modelIdentifier
        let isPrepared = appState.installedLocalModelFiles.contains {
            $0.category == .whisper && $0.modelIdentifier == activeModelIdentifier
        }

        return isPrepared ? "READY" : "NOT READY"
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

    private var mainWindowPageBinding: Binding<MainWindowPage> {
        Binding(
            get: { appState.mainWindowPage },
            set: { appState.showMainWindowPage($0) }
        )
    }

    private var isWhisperModelPreparationActive: Bool {
        switch appState.transcriptionState {
        case .preparingModel, .downloadingModel:
            return true
        case .idle, .transcribing, .preparingRefinementModel, .downloadingRefinementModel, .refining:
            return false
        }
    }

    private var whisperModelPreparationProgress: Double? {
        switch appState.transcriptionState {
        case .downloadingModel(_, let progress):
            return progress
        case .idle, .preparingModel, .transcribing, .preparingRefinementModel, .downloadingRefinementModel, .refining:
            return nil
        }
    }

    private var whisperModelDownloadStatusTitle: String {
        switch appState.transcriptionState {
        case .preparingModel(let model), .downloadingModel(let model, _):
            return "Downloading \(model.displayName)"
        case .idle, .transcribing, .preparingRefinementModel, .downloadingRefinementModel, .refining:
            return "Download failed"
        }
    }

    private var isRefinementModelPreparationActive: Bool {
        switch appState.transcriptionState {
        case .preparingRefinementModel, .downloadingRefinementModel:
            return true
        case .idle, .preparingModel, .downloadingModel, .transcribing, .refining:
            return false
        }
    }

    private var refinementModelPreparationProgress: Double? {
        switch appState.transcriptionState {
        case .downloadingRefinementModel(_, let progress):
            return progress
        case .idle, .preparingModel, .downloadingModel, .transcribing, .preparingRefinementModel, .refining:
            return nil
        }
    }

    private var refinementModelDownloadStatusTitle: String {
        switch appState.transcriptionState {
        case .preparingRefinementModel(let model), .downloadingRefinementModel(let model, _):
            return "Downloading \(model.displayName)"
        case .idle, .preparingModel, .downloadingModel, .transcribing, .refining:
            return "Download failed"
        }
    }

    private var recordingPlaybackBehaviorBinding: Binding<RecordingPlaybackBehavior> {
        Binding(
            get: { appState.recordingPlaybackBehavior },
            set: { appState.updateRecordingPlaybackBehavior($0) }
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

    private var automaticUpdateChecksBinding: Binding<Bool> {
        Binding(
            get: { appState.automaticallyChecksForUpdates },
            set: { appState.updateAutomaticallyChecksForUpdates($0) }
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
            return "LLM refinement: Off"
        case .skipped:
            return "LLM refinement: Skipped"
        case .succeeded(let model, _, _):
            return "LLM refinement: Used \(model.displayName)"
        case .failed(let model, _, _):
            return "LLM refinement: Failed with \(model.displayName)"
        }
    }

    private func refinementStatusDetail(for transcription: WhisperTranscriptionResult) -> String {
        switch transcription.refinementStatus {
        case .disabled:
            return "This transcription used raw Whisper text because refinement was off."
        case .skipped(let reason):
            return "No LLM output was produced. \(reason)"
        case .succeeded(_, let mode, let completedAt):
            return "Mode: \(mode.title). Completed at \(completedAt.formatted(date: .omitted, time: .standard))."
        case .failed(_, let errorMessage, let completedAt):
            return "No LLM output was produced. Failed at \(completedAt.formatted(date: .omitted, time: .standard)): \(errorMessage)"
        }
    }

    private func refinementStatusColor(for transcription: WhisperTranscriptionResult) -> Color {
        switch transcription.refinementStatus {
        case .succeeded:
            return AppTheme.accent
        case .failed:
            return Color.orange.opacity(0.9)
        case .disabled, .skipped:
            return AppTheme.secondaryText
        }
    }

    private func refinementOutputText(for transcription: WhisperTranscriptionResult) -> String {
        if let refinement = transcription.refinement {
            return refinement.refinedText.isEmpty ? "Empty refined transcript" : refinement.refinedText
        }

        switch transcription.refinementStatus {
        case .disabled:
            return "No LLM output. Refinement was off for this transcription."
        case .skipped:
            return "No LLM output. Refinement was skipped."
        case .failed:
            return "No LLM output. Refinement failed, so DictaFlow inserted the raw Whisper transcript."
        case .succeeded:
            return "Empty refined transcript"
        }
    }
}

private enum AppTheme {
    static let background = Color(red: 0.090, green: 0.098, blue: 0.114)
    static let sidebar = Color(red: 0.125, green: 0.165, blue: 0.220)
    static let sidebarBorder = Color.white.opacity(0.075)
    static let barFill = Color(red: 0.108, green: 0.116, blue: 0.132)
    static let tileFill = Color(red: 0.137, green: 0.145, blue: 0.165)
    static let controlFill = Color.white.opacity(0.055)
    static let editorFill = Color.black.opacity(0.12)
    static let accent = Color(red: 0.302, green: 0.471, blue: 0.984)
    static let modelActive = Color(red: 0.275, green: 0.706, blue: 0.443)
    static let destructive = Color(red: 0.835, green: 0.235, blue: 0.286)
    static let border = Color.white.opacity(0.085)
    static let primaryText = Color(red: 0.961, green: 0.965, blue: 0.973)
    static let secondaryText = Color(red: 0.58, green: 0.60, blue: 0.64)
    static let tertiaryText = Color(red: 0.40, green: 0.43, blue: 0.48)
}

private enum AppLayout {
    static let windowMinWidth: CGFloat = 660
    static let windowMinHeight: CGFloat = 520
    static let sidebarWidth: CGFloat = 204
    static let collapsedSidebarWidth: CGFloat = 76
    static let headerHeight: CGFloat = 76
    static let contentMaxWidth: CGFloat = 640
    static let contentPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 12
    static let tilePadding: CGFloat = 14
    static let tileCornerRadius: CGFloat = 9
}

private struct DictaFlowLogo: View {
    var body: some View {
        HStack(spacing: 10) {
            DictaFlowMark()

            Text("DictaFlow")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DictaFlow")
    }
}

private struct DictaFlowMark: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white)
            HStack(alignment: .center, spacing: 2) {
                ForEach([8, 14, 20, 14, 8], id: \.self) { height in
                    Capsule(style: .continuous)
                        .fill(AppTheme.sidebar)
                        .frame(width: 2.5, height: CGFloat(height))
                }
            }
        }
        .frame(width: 32, height: 32)
    }
}

private struct SidebarCollapseButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.primaryText.opacity(isHovering ? 0.92 : 0.68))
        .background(
            isHovering ? AppTheme.controlFill : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { isHovering = $0 }
        .help("Collapse sidebar")
        .accessibilityLabel("Collapse sidebar")
    }
}

private struct CollapsedSidebarLogoButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                DictaFlowMark()
                    .opacity(isHovering ? 0 : 1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .opacity(isHovering ? 1 : 0)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(
            isHovering ? AppTheme.controlFill : Color.clear,
            in: Circle()
        )
        .onHover { isHovering = $0 }
        .help("Expand sidebar")
        .accessibilityLabel("Expand sidebar")
    }
}

private struct SidebarSection<Content: View>: View {
    let title: String
    let isCollapsed: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !isCollapsed {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(AppTheme.tertiaryText)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 3)
            }

            content
        }
    }
}

private struct SidebarItem: View {
    let page: MainWindowPage
    let title: String
    let systemImage: String
    let isCollapsed: Bool
    @Binding var selection: MainWindowPage

    private var isSelected: Bool { page == selection }

    var body: some View {
        Button {
            selection = page
        } label: {
            HStack(spacing: isCollapsed ? 0 : 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 19)

                if !isCollapsed {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))

                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(isSelected ? Color.white : AppTheme.primaryText.opacity(0.78))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(isSelected ? AppTheme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, isCollapsed ? 8 : 10)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct HelpPopover: View {
    @Binding var selection: MainWindowPage
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("HELP")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.horizontal, 10)
                .padding(.bottom, 3)

            helpButton("Keyboard & recording", systemImage: "keyboard", page: .shortcutAndAudio)
            helpButton("Permission setup", systemImage: "lock.shield", page: .permissions)
            helpButton("About DictaFlow", systemImage: "info.circle", page: .updates)
        }
        .padding(10)
        .frame(width: 230)
        .background(AppTheme.tileFill)
        .foregroundStyle(AppTheme.primaryText)
    }

    private func helpButton(_ title: String, systemImage: String, page: MainWindowPage) -> some View {
        Button {
            selection = page
            isPresented = false
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct StatusNavigationLine: View {
    let title: String
    let value: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 20)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.tertiaryText)
            }
            .frame(height: 35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionStatusControl: View {
    let title: String
    let isAllowed: Bool
    let showsSettingsButton: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isAllowed ? Color.green.opacity(0.9) : AppTheme.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    (isAllowed ? Color.green : AppTheme.secondaryText).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )

            if showsSettingsButton {
                Button("Open System Settings", action: openSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
    }
}

private struct DetailPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
            .padding(.horizontal, AppLayout.contentPadding)
            .padding(.top, 20)
            .padding(.bottom, 22)
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
            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 3)
    }
}

private struct FormSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.65)
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.leading, 2)
    }
}

private struct SettingsFormPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 3)
    }
}

private struct SettingsFormRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)

                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 50)
    }
}

private struct RefinementModelPickerControl: View {
    let selectedModel: RefinementModelDescriptor?
    let emptySelectionTitle: String
    let isEnabled: Bool
    let isModelSelectable: (RefinementModelDescriptor) -> Bool
    let selectModel: (RefinementModelDescriptor) -> Void

    @State private var isShowingOptions = false

    var body: some View {
        Button {
            isShowingOptions.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selectedModel?.displayName ?? emptySelectionTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(width: 160, height: 28)
            .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .popover(isPresented: $isShowingOptions, arrowEdge: .top) {
            VStack(spacing: 2) {
                ForEach(RefinementModelDescriptor.allCases, id: \.self) { model in
                    let isSelectable = isModelSelectable(model)

                    Button {
                        isShowingOptions = false
                        selectModel(model)
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppTheme.primaryText)
                                .frame(width: 13, height: 16)
                                .opacity(model == selectedModel ? 1 : 0)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(AppTheme.primaryText)

                                Text("\(model.approximateDiskSizeDescription) storage · \(model.estimatedRuntimeMemoryDescription)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(AppTheme.secondaryText)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            model == selectedModel ? AppTheme.controlFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSelectable)
                    .opacity(isSelectable ? 1 : 0.45)
                }
            }
            .padding(7)
            .frame(width: 250)
            .background(AppTheme.tileFill)
            .foregroundStyle(AppTheme.primaryText)
        }
    }
}

private struct WhisperModelPickerControl: View {
    let selectedModel: WhisperModelDescriptor
    let isEnabled: Bool
    let isModelSelectable: (WhisperModelDescriptor) -> Bool
    let selectModel: (WhisperModelDescriptor) -> Void

    @State private var isShowingOptions = false

    var body: some View {
        Button {
            isShowingOptions.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selectedModel.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(width: 160, height: 28)
            .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .popover(isPresented: $isShowingOptions, arrowEdge: .top) {
            VStack(spacing: 2) {
                ForEach(WhisperModelDescriptor.allCases, id: \.self) { model in
                    let isSelectable = isModelSelectable(model)

                    Button {
                        isShowingOptions = false
                        selectModel(model)
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppTheme.primaryText)
                                .frame(width: 13, height: 16)
                                .opacity(model == selectedModel ? 1 : 0)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(AppTheme.primaryText)

                                Text(model.approximateDiskSizeDescription)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(AppTheme.secondaryText)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            model == selectedModel ? AppTheme.controlFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSelectable)
                    .opacity(isSelectable ? 1 : 0.45)
                }
            }
            .padding(7)
            .frame(width: 220)
            .background(AppTheme.tileFill)
            .foregroundStyle(AppTheme.primaryText)
        }
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

private enum TranscriptTextProminence {
    case primary
    case secondary
}

private struct TranscriptTextBlock: View {
    let title: String
    let text: String
    let prominence: TranscriptTextProminence

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)

            Text(text)
                .font(.system(size: prominence == .primary ? 15 : 13))
                .foregroundStyle(prominence == .primary ? AppTheme.primaryText : AppTheme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RefinementStatusBadge: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryText)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 0.75)
        )
    }
}

private struct OverviewFeatureCard: View {
    let title: String
    let badge: String
    let systemImage: String
    let primaryText: Text
    let secondaryText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 22)

                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))

                    Spacer()

                    Text(badge)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppTheme.tertiaryText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    primaryText
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppTheme.primaryText.opacity(0.88))

                    Text(secondaryText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineSpacing(1.5)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 95, alignment: .topLeading)
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppLayout.tileCornerRadius, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ModelPageSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)

                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Divider()
                .overlay(AppTheme.border)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EqualHeightModelGrid: Layout {
    let spacing: CGFloat

    private func columnCount(for subviews: Subviews) -> Int {
        min(2, max(1, subviews.count))
    }

    private func itemWidth(totalWidth: CGFloat, columns: Int) -> CGFloat {
        max(0, (totalWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }

    private func maximumItemHeight(subviews: Subviews, itemWidth: CGFloat) -> CGFloat {
        subviews.reduce(0) { height, subview in
            max(height, subview.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height)
        }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else {
            return .zero
        }

        let columns = columnCount(for: subviews)
        let naturalItemWidth = subviews.reduce(0) { width, subview in
            max(width, subview.sizeThatFits(.unspecified).width)
        }
        let totalWidth = proposal.width ?? (naturalItemWidth * CGFloat(columns) + spacing * CGFloat(columns - 1))
        let width = itemWidth(totalWidth: totalWidth, columns: columns)
        let height = maximumItemHeight(subviews: subviews, itemWidth: width)
        let rows = Int(ceil(Double(subviews.count) / Double(columns)))

        return CGSize(
            width: totalWidth,
            height: height * CGFloat(rows) + spacing * CGFloat(rows - 1)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else {
            return
        }

        let columns = columnCount(for: subviews)
        let width = itemWidth(totalWidth: bounds.width, columns: columns)
        let height = maximumItemHeight(subviews: subviews, itemWidth: width)

        for (index, subview) in subviews.enumerated() {
            let row = index / columns
            let column = index % columns
            let origin = CGPoint(
                x: bounds.minX + CGFloat(column) * (width + spacing),
                y: bounds.minY + CGFloat(row) * (height + spacing)
            )
            subview.place(
                at: origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: height)
            )
        }
    }
}

private struct ModelDownloadStatusPanel: View {
    let title: String
    let statusText: String
    let isActive: Bool
    let progress: Double?
    let hasFailed: Bool

    private var statusColor: Color {
        hasFailed ? Color.orange : (isActive ? AppTheme.accent : AppTheme.secondaryText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: hasFailed ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                    .foregroundStyle(statusColor)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
            }

            if isActive {
                if let progress {
                    ProgressView(value: progress)
                        .tint(AppTheme.accent)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: hasFailed ? .leading : .trailing)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.editorFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusColor.opacity(hasFailed || isActive ? 0.35 : 0.14), lineWidth: 0.75)
        )
    }
}

private struct ModelChoiceCard: View {
    let name: String
    let sizeText: String
    let detailText: String
    let isActive: Bool
    let needsPreparation: Bool
    let isUnavailable: Bool
    let isInteractionLocked: Bool
    let deleteAction: (() -> Void)?
    let action: () -> Void

    private var stateColor: Color {
        if isActive {
            return AppTheme.modelActive
        }

        if isUnavailable {
            return AppTheme.tertiaryText
        }

        if needsPreparation {
            return Color.orange
        }

        return AppTheme.accent
    }

    private var cardTint: Color {
        if isUnavailable {
            return AppTheme.controlFill
        }

        let opacity: Double
        if isInteractionLocked {
            opacity = 0.045
        } else if isActive {
            opacity = 0.12
        } else {
            opacity = 0.06
        }
        return stateColor.opacity(opacity)
    }

    private var borderColor: Color {
        if isUnavailable {
            return AppTheme.tertiaryText.opacity(0.28)
        }

        if isInteractionLocked {
            return stateColor.opacity(0.25)
        }

        return stateColor.opacity(isActive ? 0.85 : 0.42)
    }

    private var accessibilityHint: String {
        if isActive {
            return "Current active model"
        }

        if isUnavailable {
            return "This model is unavailable on this Mac"
        }

        if needsPreparation {
            return "Downloads this model"
        }

        return "Uses this prepared model"
    }

    @ViewBuilder
    private var modelAction: some View {
        if isActive {
            Label("ACTIVE", systemImage: "checkmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(isInteractionLocked ? 0.65 : 1))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    stateColor.opacity(isInteractionLocked ? 0.38 : 1),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        } else if isUnavailable {
            Text("UNAVAILABLE")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else if needsPreparation {
            Button(action: action) {
                Label("DOWNLOAD", systemImage: "arrow.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(isInteractionLocked ? 0.58 : 1))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        stateColor.opacity(isInteractionLocked ? 0.34 : 0.92),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isInteractionLocked)
            .accessibilityHint(accessibilityHint)
        } else {
            Button(action: action) {
                Label("USE", systemImage: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.white.opacity(isInteractionLocked ? 0.58 : 1))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        stateColor.opacity(isInteractionLocked ? 0.34 : 0.92),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isInteractionLocked)
            .accessibilityHint(accessibilityHint)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                if let deleteAction {
                    Button(action: deleteAction) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white.opacity(isInteractionLocked ? 0.58 : 1))
                            .frame(width: 24, height: 23)
                            .background(
                                AppTheme.destructive.opacity(isInteractionLocked ? 0.34 : 0.9),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isInteractionLocked)
                    .help("Delete downloaded model")
                }

                modelAction
            }

            Text(sizeText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(stateColor.opacity(isInteractionLocked ? 0.58 : 1))

            Text(detailText)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.tileFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(cardTint)
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    borderColor,
                    lineWidth: isActive ? 1.25 : 0.75
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
        .accessibilityAddTraits(isActive ? .isSelected : [])
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
