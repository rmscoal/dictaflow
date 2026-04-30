import AppKit
import Combine
import Foundation

@MainActor
protocol MainWindowRouting: AnyObject {
    func showMainWindow()
    func closeMainWindow()
}

@MainActor
protocol SettingsWindowRouting: AnyObject {
    func showSettingsWindow()
}

enum MainWindowPage {
    case dashboard
    case models
    case settings
    case history
}

@MainActor
final class DictaFlowAppState: ObservableObject {
    @Published private(set) var isMainWindowVisible = false
    @Published private(set) var isSettingsWindowVisible = false
    @Published var mainWindowPage: MainWindowPage = .dashboard
    @Published private(set) var microphonePermissionState: MicrophonePermissionState
    @Published private(set) var accessibilityPermissionState: AccessibilityPermissionState
    @Published private(set) var recordingState: DictationRecordingState
    @Published private(set) var transcriptionState: TranscriptionPipelineState
    @Published private(set) var textInsertionState: TextInsertionState
    @Published private(set) var lastCapture: DictationCapture?
    @Published private(set) var lastTranscription: WhisperTranscriptionResult?
    @Published private(set) var lastTextInsertion: TextInsertionResult?
    @Published private(set) var statusMessage: String
    @Published private(set) var isHotkeyRegistered = false
    @Published private(set) var modelDownloadProgressText: String?

    let launchExperience: AppLaunchExperience
    @Published private(set) var whisperConfiguration: WhisperConfiguration
    @Published private(set) var refinementConfiguration: RefinementConfiguration

    private let settingsStore: SettingsStoreProtocol
    private let permissionService: PermissionServiceProtocol
    private let audioRecorderService: AudioRecorderServiceProtocol
    private let hotkeyService: HotkeyServiceProtocol
    private let modelDownloadService: ModelDownloadServiceProtocol
    private let whisperService: WhisperServiceProtocol
    private let transcriptRefinementService: TranscriptRefinementServiceProtocol
    private let textInsertionService: TextInsertionServiceProtocol
    private weak var mainWindowRouter: MainWindowRouting?
    private weak var settingsWindowRouter: SettingsWindowRouting?
    private var workspaceObservers = Set<AnyCancellable>()
    private var lastKnownExternalTargetApplication: InsertionTargetApplication?
    private var pendingInsertionTargetApplication: InsertionTargetApplication?
    private var preservedStatusMessage: String?

    convenience init() {
        self.init(
            settingsStore: UserDefaultsSettingsStore(),
            permissionService: SystemPermissionService(),
            audioRecorderService: SystemAudioRecorderService(),
            hotkeyService: CarbonHotkeyService(),
            modelDownloadService: WhisperModelDownloadService(),
            whisperService: WhisperCPPService(),
            transcriptRefinementService: LlamaCLITranscriptRefinementService(),
            textInsertionService: SystemTextInsertionService()
        )
    }

    init(
        settingsStore: SettingsStoreProtocol,
        permissionService: PermissionServiceProtocol,
        audioRecorderService: AudioRecorderServiceProtocol,
        hotkeyService: HotkeyServiceProtocol,
        modelDownloadService: ModelDownloadServiceProtocol,
        whisperService: WhisperServiceProtocol,
        transcriptRefinementService: TranscriptRefinementServiceProtocol,
        textInsertionService: TextInsertionServiceProtocol
    ) {
        self.settingsStore = settingsStore
        self.permissionService = permissionService
        self.audioRecorderService = audioRecorderService
        self.hotkeyService = hotkeyService
        self.modelDownloadService = modelDownloadService
        self.whisperService = whisperService
        self.transcriptRefinementService = transcriptRefinementService
        self.textInsertionService = textInsertionService
        self.launchExperience = settingsStore.shouldShowMainWindowOnLaunch ? .firstLaunch : .returningUser
        self.whisperConfiguration = settingsStore.whisperConfiguration
        self.refinementConfiguration = settingsStore.refinementConfiguration
        self.isSettingsWindowVisible = false
        self.microphonePermissionState = permissionService.currentMicrophonePermissionStatus()
        self.accessibilityPermissionState = AccessibilityPermissionState(
            isGranted: permissionService.isAccessibilityPermissionGranted(),
            hasRequestedBefore: settingsStore.hasRequestedAccessibilityPermission
        )
        self.recordingState = .idle
        self.transcriptionState = .idle
        self.textInsertionState = .idle
        self.lastCapture = nil
        self.lastTranscription = nil
        self.lastTextInsertion = nil
        self.statusMessage = ""
        self.modelDownloadProgressText = nil
        self.preservedStatusMessage = nil
        self.lastKnownExternalTargetApplication = Self.makeInsertionTargetApplication(from: NSWorkspace.shared.frontmostApplication)
        configureWorkspaceObservers()
        updateStatusMessage()
    }

    var menuBarIconName: String {
        if recordingState.isRecording {
            return "mic.circle.fill"
        }

        if transcriptionState.isTranscribing || transcriptionState.isRefining {
            return "waveform.badge.magnifyingglass"
        }

        if textInsertionState.isBusy {
            return "text.cursor"
        }

        if let lastTextInsertion, lastTextInsertion.method == .copyPanel {
            return "doc.on.clipboard"
        }

        return isMainWindowVisible ? "waveform.circle.fill" : "waveform.circle"
    }

    var menuBarStatusText: String {
        switch transcriptionState {
        case .idle:
            break
        case .preparingModel(let model):
            return "Preparing \(model.displayName) model"
        case .downloadingModel(let model, _):
            return "Downloading \(model.displayName) model"
        case .transcribing:
            return "Running Whisper locally"
        case .preparingRefinementModel(let model):
            return "Preparing \(model.displayName)"
        case .downloadingRefinementModel(let model, _):
            return "Downloading \(model.displayName)"
        case .refining:
            return "Refining locally"
        }

        switch textInsertionState {
        case .idle:
            break
        case .requestingAccessibilityPermission:
            return "Waiting for Accessibility permission"
        case .inserting(let targetApplicationName):
            return "Inserting into \(targetApplicationName ?? "target app")"
        }

        if recordingState.isRecording {
            return "Recording in progress"
        }

        if let lastTextInsertion {
            return lastTextInsertion.method.title
        }

        return "Ready"
    }

    var launchBehaviorText: String {
        launchExperience.summary
    }

    var dictationActionTitle: String {
        recordingState.isRecording ? "Stop Recording" : "Start Recording"
    }

    var dictationActionSymbolName: String {
        if recordingState.isRecording {
            return "stop.circle.fill"
        }

        if transcriptionState.isTranscribing || transcriptionState.isRefining {
            return "waveform.badge.magnifyingglass"
        }

        if textInsertionState.isBusy {
            return "text.cursor"
        }

        return "mic.circle.fill"
    }

    var dictationSummaryText: String {
        switch recordingState {
        case .idle:
            break
        case .requestingPermission:
            return "Requesting microphone access."
        case .recording(let startedAt, _):
            return "Recording since \(startedAt.formatted(date: .omitted, time: .standard))."
        case .stopping:
            return "Finalizing the local recording file."
        }

        switch transcriptionState {
        case .idle:
            break
        case .preparingModel(let model):
            return "Preparing the local \(model.displayName) Whisper model."
        case .downloadingModel(let model, let progress):
            let progressSuffix: String
            if let progress {
                progressSuffix = " \(Int(progress * 100))% complete."
            } else {
                progressSuffix = ""
            }
            return "Downloading the local \(model.displayName) Whisper model.\(progressSuffix)"
        case .transcribing(let model):
            return "Transcribing locally with the \(model.displayName) model."
        case .preparingRefinementModel(let model):
            return "Preparing the local \(model.displayName) refinement model."
        case .downloadingRefinementModel(let model, let progress):
            let progressSuffix: String
            if let progress {
                progressSuffix = " \(Int(progress * 100))% complete."
            } else {
                progressSuffix = ""
            }
            return "Downloading the local \(model.displayName) refinement model.\(progressSuffix)"
        case .refining(let model):
            return "Refining the transcript locally with \(model.displayName)."
        }

        switch textInsertionState {
        case .idle:
            break
        case .requestingAccessibilityPermission(let targetApplicationName):
            return "Requesting Accessibility permission before inserting into \(targetApplicationName ?? "the target app")."
        case .inserting(let targetApplicationName):
            return "Inserting the finished transcript into \(targetApplicationName ?? "the focused app")."
        }

        return "Ready to record, transcribe locally with Whisper, and insert text into the focused app."
    }

    var hotkeyDisplayText: String {
        GlobalShortcutDescriptor.toggleDictation.displayValue
    }

    var modelsDirectoryPath: String {
        modelDownloadService.modelsDirectoryURL.path
    }

    var modelStatusText: String {
        switch transcriptionState {
        case .idle:
            return "\(whisperConfiguration.model.displayName) model stored in \(modelsDirectoryPath)"
        case .preparingModel(let model):
            return "Preparing \(model.displayName) in \(modelsDirectoryPath)"
        case .downloadingModel(let model, _):
            return modelDownloadProgressText ?? "Downloading \(model.displayName) to \(modelsDirectoryPath)"
        case .transcribing(let model):
            return "Using \(model.displayName) from \(modelsDirectoryPath)"
        case .preparingRefinementModel(let model):
            return "Preparing \(model.displayName) in \(modelsDirectoryPath)"
        case .downloadingRefinementModel(let model, _):
            return modelDownloadProgressText ?? "Downloading \(model.displayName) to \(modelsDirectoryPath)"
        case .refining(let model):
            return "Using \(model.displayName) from \(modelsDirectoryPath)"
        }
    }

    var whisperConfigurationSummaryText: String {
        let refinementText = refinementConfiguration.isEnabled ? "Refinement On" : "Refinement Off"
        return "\(whisperConfiguration.taskMode.title) • \(whisperConfiguration.inputLanguage.displayName) • \(whisperConfiguration.model.displayName) • \(refinementText)"
    }

    var refinementStatusText: String {
        if let progress = modelDownloadProgressText,
           case .downloadingRefinementModel = transcriptionState {
            return progress
        }

        if let unsupportedReason = refinementModelSupport(for: refinementConfiguration.model).unsupportedReason {
            return "\(refinementConfiguration.model.displayName) is unavailable on this Mac. \(unsupportedReason)"
        }

        if refinementConfiguration.isEnabled {
            return "Cleans transcripts locally before insertion."
        }

        if !hasPreparedRefinementModel {
            return "Choose and prepare a local refinement model before turning this on."
        }

        return "Refinement is off. DictaFlow will insert the raw Whisper transcript."
    }

    var hasPreparedRefinementModel: Bool {
        RefinementModelDescriptor.allCases.contains {
            modelDownloadService.isRefinementModelPrepared($0) && refinementModelSupport(for: $0).isSupported
        }
    }

    var isSelectedRefinementModelPrepared: Bool {
        isSelectedRefinementModelSupported && modelDownloadService.isRefinementModelPrepared(refinementConfiguration.model)
    }

    var isSelectedRefinementModelSupported: Bool {
        refinementModelSupport(for: refinementConfiguration.model).isSupported
    }

    var refinementHardwareProfile: MacHardwareProfile {
        MacHardwareProfile.current(modelsDirectoryURL: modelDownloadService.modelsDirectoryURL)
    }

    var refinementRecommendation: RefinementModelRecommendation {
        RefinementModelRecommendation(
            hardwareProfile: refinementHardwareProfile,
            preparedModels: preparedRefinementModels
        )
    }

    func refinementModelSupport(for model: RefinementModelDescriptor) -> RefinementModelSupport {
        refinementRecommendation.support(for: model)
    }

    func isRefinementModelSupported(_ model: RefinementModelDescriptor) -> Bool {
        refinementModelSupport(for: model).isSupported
    }

    func refinementModelPickerTitle(for model: RefinementModelDescriptor) -> String {
        let badges = refinementModelBadges(for: model).joined(separator: ", ")
        let baseTitle = "\(model.displayName) (\(model.approximateDiskSizeDescription), \(model.estimatedRuntimeMemoryDescription))"
        return badges.isEmpty ? baseTitle : "\(baseTitle) - \(badges)"
    }

    func refinementModelMenuTitle(for model: RefinementModelDescriptor) -> String {
        let compactBadges = refinementModelBadges(for: model).map { badge in
            switch badge {
            case "Best quality":
                return "Best"
            case "Recommended for this Mac":
                return "Rec"
            case "Unavailable on this Mac":
                return "Unavailable"
            default:
                return badge
            }
        }

        return compactBadges.isEmpty ? model.displayName : "\(model.displayName) (\(compactBadges.joined(separator: ", ")))"
    }

    func refinementModelDetailText(for model: RefinementModelDescriptor) -> String {
        let support = refinementModelSupport(for: model)

        if let unsupportedReason = support.unsupportedReason {
            return "\(unsupportedReason) \(model.detailText)"
        }

        let badges = refinementModelBadges(for: model)

        if badges.contains("Best quality"), badges.contains("Recommended for this Mac") {
            return "Best quality and recommended for this Mac. \(model.detailText)"
        }

        if badges.contains("Best quality") {
            return "Best quality, but above this Mac's recommendation if not also marked recommended. \(model.detailText)"
        }

        if badges.contains("Recommended for this Mac") {
            return "Recommended for this Mac. \(model.detailText)"
        }

        return model.detailText
    }

    private func refinementModelBadges(for model: RefinementModelDescriptor) -> [String] {
        let recommendation = refinementRecommendation
        let support = recommendation.support(for: model)

        if !support.isSupported {
            return ["Unavailable on this Mac"]
        }

        var badges: [String] = []

        if model == recommendation.bestModel {
            badges.append("Best quality")
        }

        if model == recommendation.recommendedModel {
            badges.append("Recommended for this Mac")
        }

        return badges
    }

    var whisperSettingsLocked: Bool {
        switch recordingState {
        case .idle:
            break
        case .requestingPermission, .recording, .stopping:
            return true
        }

        return transcriptionState.isBusy || textInsertionState.isBusy
    }

    var supportedWhisperLanguages: [WhisperLanguageOption] {
        WhisperLanguageCatalog.supportedLanguages
    }

    var commonWhisperLanguages: [WhisperLanguageOption] {
        WhisperLanguageCatalog.commonLanguages
    }

    var additionalWhisperLanguages: [WhisperLanguageOption] {
        WhisperLanguageCatalog.additionalLanguages
    }

    var installedLocalModelFiles: [LocalModelFile] {
        modelDownloadService.installedModelFiles()
    }

    var unusedLocalModelFiles: [LocalModelFile] {
        installedLocalModelFiles.filter { !isActiveLocalModelFile($0) }
    }

    var canReviewUnusedModelDeletion: Bool {
        !whisperSettingsLocked && !unusedLocalModelFiles.isEmpty
    }

    var modelStorageStatusText: String {
        let installedFiles = installedLocalModelFiles

        guard !installedFiles.isEmpty else {
            return "No local model files are stored yet."
        }

        let unusedFiles = installedFiles.filter { !isActiveLocalModelFile($0) }

        guard !unusedFiles.isEmpty else {
            return "Only active local models are stored."
        }

        return "\(unusedFiles.count) unused \(unusedFiles.count == 1 ? "model" : "models") can be deleted to free \(formattedLocalModelSize(totalByteCount(for: unusedFiles)))."
    }

    func isActiveLocalModelFile(_ file: LocalModelFile) -> Bool {
        activeLocalModelIdentifiers.contains(file.modelIdentifier)
    }

    func formattedLocalModelSize(_ byteCount: Int64) -> String {
        Self.formattedByteCount(byteCount)
    }

    private var preparedRefinementModels: Set<RefinementModelDescriptor> {
        Set(RefinementModelDescriptor.allCases.filter { modelDownloadService.isRefinementModelPrepared($0) })
    }

    private var activeLocalModelIdentifiers: Set<String> {
        [
            whisperConfiguration.model.modelIdentifier,
            refinementConfiguration.model.modelIdentifier
        ]
    }

    var textInsertionStatusText: String {
        if let lastTextInsertion {
            return lastTextInsertion.summaryText
        }

        switch textInsertionState {
        case .idle:
            return "Automatic insertion will try Accessibility first, then paste, simulated typing, and finally a manual copy panel."
        case .requestingAccessibilityPermission(let targetApplicationName):
            return "Waiting for Accessibility approval before targeting \(targetApplicationName ?? "the current app")."
        case .inserting(let targetApplicationName):
            return "Trying to insert into \(targetApplicationName ?? "the current app")."
        }
    }

    var canInsertLastTranscription: Bool {
        guard let lastTranscription else {
            return false
        }

        return !lastTranscription.insertionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !recordingState.isRecording
            && !transcriptionState.isBusy
            && !textInsertionState.isBusy
    }

    var canCopyLastTranscription: Bool {
        guard let lastTranscription else {
            return false
        }

        return !lastTranscription.insertionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func attach(mainWindowRouter: MainWindowRouting) {
        self.mainWindowRouter = mainWindowRouter
    }

    func attach(settingsWindowRouter: SettingsWindowRouting) {
        self.settingsWindowRouter = settingsWindowRouter
    }

    func handleApplicationLaunch() {
        refreshMicrophonePermissionStatus()
        refreshAccessibilityPermissionStatus()
        registerGlobalHotkey()
        prepareDefaultModelIfNeeded()

        if launchExperience == .firstLaunch {
            showMainWindow()
            settingsStore.markInitialWindowPresentationComplete()
        }

        updateStatusMessage()
    }

    func showMainWindow() {
        mainWindowPage = .dashboard
        mainWindowRouter?.showMainWindow()
    }

    func showMainWindowPage(_ page: MainWindowPage) {
        mainWindowPage = page
        mainWindowRouter?.showMainWindow()
    }

    func openSettingsWindow() {
        showMainWindowPage(.settings)
    }

    func closeMainWindow() {
        mainWindowRouter?.closeMainWindow()
    }

    func toggleMainWindow() {
        isMainWindowVisible ? closeMainWindow() : showMainWindow()
    }

    func updateTaskMode(_ taskMode: WhisperTaskMode) {
        guard whisperConfiguration.taskMode != taskMode else {
            return
        }

        whisperConfiguration.taskMode = taskMode
        persistWhisperConfiguration()
        updateStatusMessage()
    }

    func updateInputLanguage(_ inputLanguage: WhisperInputLanguage) {
        guard whisperConfiguration.inputLanguage != inputLanguage else {
            return
        }

        whisperConfiguration.inputLanguage = inputLanguage
        persistWhisperConfiguration()
        updateStatusMessage()
    }

    func updateRefinementEnabled(_ isEnabled: Bool) {
        guard refinementConfiguration.isEnabled != isEnabled else {
            return
        }

        guard !isEnabled || isSelectedRefinementModelSupported else {
            setPreservedStatusMessage(unsupportedRefinementModelMessage(for: refinementConfiguration.model))
            showMainWindow()
            return
        }

        guard !isEnabled || isSelectedRefinementModelPrepared else {
            mainWindowPage = .settings
            setPreservedStatusMessage("Choose and prepare a refinement model before turning on local cleanup.")
            showMainWindow()
            return
        }

        refinementConfiguration.isEnabled = isEnabled
        persistRefinementConfiguration()
        updateStatusMessage()
    }

    func updateRefinementModel(_ model: RefinementModelDescriptor) {
        guard refinementConfiguration.model != model else {
            return
        }

        guard isRefinementModelSupported(model) else {
            setPreservedStatusMessage(unsupportedRefinementModelMessage(for: model))
            return
        }

        refinementConfiguration.model = model
        persistRefinementConfiguration()
        updateStatusMessage()
    }

    func resetWhisperSettingsToDefaults() {
        whisperConfiguration = .default
        refinementConfiguration = .default
        persistWhisperConfiguration()
        persistRefinementConfiguration()
        updateStatusMessage()
    }

    func refreshMicrophonePermissionStatus() {
        microphonePermissionState = permissionService.currentMicrophonePermissionStatus()
        updateStatusMessage()
    }

    func refreshAccessibilityPermissionStatus() {
        accessibilityPermissionState = resolvedAccessibilityPermissionState()
        updateStatusMessage()
    }

    func retryModelPreparation() {
        prepareDefaultModelIfNeeded()
    }

    func prepareAndUseModel(_ model: WhisperModelDescriptor) {
        if whisperConfiguration.model != model {
            whisperConfiguration.model = model
            persistWhisperConfiguration()
            updateStatusMessage()
        }

        prepareDefaultModelIfNeeded()
    }

    func prepareRefinementModel() {
        prepareRefinementModelIfNeeded(force: true)
    }

    func prepareAndUseRefinementModel(_ model: RefinementModelDescriptor) {
        guard isRefinementModelSupported(model) else {
            setPreservedStatusMessage(unsupportedRefinementModelMessage(for: model))
            return
        }

        if refinementConfiguration.model != model {
            refinementConfiguration.model = model
            persistRefinementConfiguration()
            updateStatusMessage()
        }

        prepareRefinementModelIfNeeded(force: true, enableAfterPreparation: true)
    }

    func toggleDictation() {
        Task { @MainActor [weak self] in
            await self?.performDictationToggle()
        }
    }

    func insertLastTranscription() {
        guard canInsertLastTranscription, let lastTranscription else {
            return
        }

        pendingInsertionTargetApplication = captureCurrentInsertionTargetApplication()

        Task { @MainActor [weak self] in
            await self?.insert(transcription: lastTranscription, targetApplication: self?.pendingInsertionTargetApplication)
        }
    }

    func copyLastTranscription() {
        guard let lastTranscription else {
            return
        }

        textInsertionService.copyTextToPasteboard(lastTranscription.insertionText)
        setPreservedStatusMessage("Copied the last transcript to the clipboard for manual paste.")
    }

    func openAccessibilitySettings() {
        permissionService.openAccessibilitySettings()
    }

    func openModelsFolder() {
        let modelsDirectoryURL = modelDownloadService.modelsDirectoryURL
        try? FileManager.default.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(modelsDirectoryURL)
    }

    func deleteUnusedModelFiles(matching candidates: [LocalModelFile]) {
        guard !whisperSettingsLocked else {
            setPreservedStatusMessage("Wait until the current recording, transcription, or model preparation finishes before deleting models.")
            return
        }

        let candidateIdentifiers = Set(candidates.map(\.modelIdentifier))
        let filesToDelete = unusedLocalModelFiles.filter { candidateIdentifiers.contains($0.modelIdentifier) }

        guard !filesToDelete.isEmpty else {
            setPreservedStatusMessage("No unused local models are available to delete.")
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let deletedByteCount = try await self.modelDownloadService.deleteModelFiles(filesToDelete)

                await MainActor.run {
                    let fileCount = filesToDelete.count
                    self.modelDownloadProgressText = nil
                    self.setPreservedStatusMessage("Deleted \(fileCount) unused \(fileCount == 1 ? "model" : "models") and freed \(self.formattedLocalModelSize(deletedByteCount)).")
                }
            } catch {
                await MainActor.run {
                    self.setPreservedStatusMessage("Could not delete unused models. \(error.localizedDescription)")
                }
            }
        }
    }

    func prepareForTermination() {
        hotkeyService.unregisterToggleHotkey()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func mainWindowDidOpen() {
        isMainWindowVisible = true
        updateStatusMessage()
    }

    func mainWindowDidClose() {
        isMainWindowVisible = false
        updateStatusMessage()
    }

    func settingsWindowDidOpen() {
        isSettingsWindowVisible = true
        updateStatusMessage()
    }

    func settingsWindowDidClose() {
        isSettingsWindowVisible = false
        updateStatusMessage()
    }

    private func registerGlobalHotkey() {
        do {
            try hotkeyService.registerToggleHotkey { [weak self] in
                self?.toggleDictation()
            }
            isHotkeyRegistered = true
        } catch {
            isHotkeyRegistered = false
            setPreservedStatusMessage(error.localizedDescription)
            showMainWindow()
        }
    }

    private func prepareDefaultModelIfNeeded() {
        guard !recordingState.isRecording, !transcriptionState.isBusy else {
            return
        }

        let model = whisperConfiguration.model
        transcriptionState = .preparingModel(model)
        modelDownloadProgressText = nil
        updateStatusMessage()

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                _ = try await self.modelDownloadService.ensureModelAvailable(model) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.apply(modelDownloadEvent: event, for: model)
                    }
                }

                await MainActor.run {
                    if case .transcribing = self.transcriptionState {
                        return
                    }

                    self.transcriptionState = .idle
                    self.modelDownloadProgressText = "Ready at \(self.modelsDirectoryPath)"
                    self.updateStatusMessage()
                }
            } catch {
                await MainActor.run {
                    self.transcriptionState = .idle
                    self.modelDownloadProgressText = nil
                    self.setPreservedStatusMessage("Could not prepare the Whisper model. \(error.localizedDescription)")
                    self.showMainWindow()
                }
            }
        }
    }

    private func prepareRefinementModelIfNeeded(force: Bool = false, enableAfterPreparation: Bool = false) {
        guard force || refinementConfiguration.isEnabled else {
            return
        }

        guard !recordingState.isRecording, !transcriptionState.isBusy else {
            return
        }

        let model = refinementConfiguration.model

        guard isRefinementModelSupported(model) else {
            setPreservedStatusMessage(unsupportedRefinementModelMessage(for: model))
            showMainWindow()
            return
        }

        transcriptionState = .preparingRefinementModel(model)
        modelDownloadProgressText = nil
        updateStatusMessage()

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                _ = try await self.modelDownloadService.ensureRefinementModelAvailable(model) { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.apply(refinementModelDownloadEvent: event, for: model)
                    }
                }

                await MainActor.run {
                    if case .refining = self.transcriptionState {
                        return
                    }

                    if enableAfterPreparation {
                        self.refinementConfiguration.isEnabled = true
                        self.persistRefinementConfiguration()
                    }

                    self.transcriptionState = .idle
                    self.modelDownloadProgressText = "Ready at \(self.modelsDirectoryPath)"
                    self.updateStatusMessage()
                }
            } catch {
                await MainActor.run {
                    self.transcriptionState = .idle
                    self.modelDownloadProgressText = nil
                    self.setPreservedStatusMessage("Could not prepare the refinement model. \(error.localizedDescription)")
                    self.showMainWindow()
                }
            }
        }
    }

    private func apply(modelDownloadEvent: ModelDownloadEvent, for model: WhisperModelDescriptor) {
        switch modelDownloadEvent {
        case .located(let url):
            if case .transcribing = transcriptionState {
                modelDownloadProgressText = "Using cached model at \(url.path)"
            } else {
                transcriptionState = .idle
                modelDownloadProgressText = "Ready at \(url.path)"
            }
        case .starting(let expectedBytes):
            transcriptionState = .downloadingModel(model, progress: nil)
            modelDownloadProgressText = formattedModelProgress(bytesWritten: 0, totalBytes: expectedBytes)
        case .downloading(let bytesWritten, let totalBytes):
            let progress: Double?
            if let totalBytes, totalBytes > 0 {
                progress = min(1, max(0, Double(bytesWritten) / Double(totalBytes)))
            } else {
                progress = nil
            }
            transcriptionState = .downloadingModel(model, progress: progress)
            modelDownloadProgressText = formattedModelProgress(bytesWritten: bytesWritten, totalBytes: totalBytes)
        case .finished(let url):
            modelDownloadProgressText = "Downloaded to \(url.path)"
        }

        updateStatusMessage()
    }

    private func apply(refinementModelDownloadEvent event: ModelDownloadEvent, for model: RefinementModelDescriptor) {
        switch event {
        case .located(let url):
            if case .refining = transcriptionState {
                modelDownloadProgressText = "Using cached model at \(url.path)"
            } else {
                transcriptionState = .idle
                modelDownloadProgressText = "Ready at \(url.path)"
            }
        case .starting(let expectedBytes):
            transcriptionState = .downloadingRefinementModel(model, progress: nil)
            modelDownloadProgressText = formattedModelProgress(
                modelName: model.displayName,
                bytesWritten: 0,
                totalBytes: expectedBytes
            )
        case .downloading(let bytesWritten, let totalBytes):
            let progress: Double?
            if let totalBytes, totalBytes > 0 {
                progress = min(1, max(0, Double(bytesWritten) / Double(totalBytes)))
            } else {
                progress = nil
            }
            transcriptionState = .downloadingRefinementModel(model, progress: progress)
            modelDownloadProgressText = formattedModelProgress(
                modelName: model.displayName,
                bytesWritten: bytesWritten,
                totalBytes: totalBytes
            )
        case .finished(let url):
            modelDownloadProgressText = "Downloaded to \(url.path)"
        }

        updateStatusMessage()
    }

    private func formattedModelProgress(bytesWritten: Int64, totalBytes: Int64?) -> String {
        formattedModelProgress(
            modelName: whisperConfiguration.model.displayName,
            bytesWritten: bytesWritten,
            totalBytes: totalBytes
        )
    }

    private func formattedModelProgress(modelName: String, bytesWritten: Int64, totalBytes: Int64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        let writtenText = formatter.string(fromByteCount: bytesWritten)

        if let totalBytes, totalBytes > 0 {
            let totalText = formatter.string(fromByteCount: totalBytes)
            return "Downloading \(modelName) model: \(writtenText) of \(totalText)"
        }

        return "Downloading \(modelName) model: \(writtenText)"
    }

    private func totalByteCount(for files: [LocalModelFile]) -> Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    private static func formattedByteCount(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }

    private func unsupportedRefinementModelMessage(for model: RefinementModelDescriptor) -> String {
        if let unsupportedReason = refinementModelSupport(for: model).unsupportedReason {
            return "\(model.displayName) is unavailable on this Mac. \(unsupportedReason) Choose a smaller model."
        }

        return "\(model.displayName) is unavailable on this Mac. Choose a smaller model."
    }

    private func persistWhisperConfiguration() {
        settingsStore.saveWhisperConfiguration(whisperConfiguration)
    }

    private func persistRefinementConfiguration() {
        settingsStore.saveRefinementConfiguration(refinementConfiguration)
    }

    private func performDictationToggle() async {
        if transcriptionState.isBusy || textInsertionState.isBusy {
            return
        }

        switch recordingState {
        case .requestingPermission, .stopping:
            return
        case .idle:
            await beginRecordingFlow()
        case .recording:
            await finishRecordingFlow()
        }
    }

    private func beginRecordingFlow() async {
        clearPreservedStatusMessage()
        pendingInsertionTargetApplication = captureCurrentInsertionTargetApplication()
        recordingState = .requestingPermission
        updateStatusMessage()

        let permissionState = await permissionService.requestMicrophonePermissionIfNeeded()
        microphonePermissionState = permissionState

        guard permissionState == .granted else {
            recordingState = .idle
            updateStatusMessage()
            showMainWindow()
            return
        }

        do {
            let fileURL = try await audioRecorderService.startRecording()
            recordingState = .recording(startedAt: Date(), fileURL: fileURL)
            updateStatusMessage()
        } catch {
            recordingState = .idle
            setPreservedStatusMessage("Could not start recording. \(error.localizedDescription)")
            showMainWindow()
        }
    }

    private func finishRecordingFlow() async {
        recordingState = .stopping
        updateStatusMessage()

        do {
            let capture = try await audioRecorderService.stopRecording()
            lastCapture = capture
            microphonePermissionState = permissionService.currentMicrophonePermissionStatus()
            recordingState = .idle
            updateStatusMessage()
            await transcribe(capture: capture)
        } catch {
            recordingState = .idle
            setPreservedStatusMessage("Could not stop recording cleanly. \(error.localizedDescription)")
            showMainWindow()
        }
    }

    private func transcribe(capture: DictationCapture) async {
        let model = whisperConfiguration.model

        if !transcriptionState.isPreparingModel {
            transcriptionState = .preparingModel(model)
            modelDownloadProgressText = nil
            updateStatusMessage()
        }

        do {
            let modelURL = try await modelDownloadService.ensureModelAvailable(model) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.apply(modelDownloadEvent: event, for: model)
                }
            }

            transcriptionState = .transcribing(model)
            updateStatusMessage()

            let transcription = try await whisperService.transcribe(
                audioFileURL: capture.fileURL,
                modelURL: modelURL,
                configuration: whisperConfiguration
            )

            lastTranscription = transcription
            clearPreservedStatusMessage()
            transcriptionState = .idle
            updateStatusMessage()
            let insertionTranscription = await refinedTranscriptionIfNeeded(transcription)
            await insert(transcription: insertionTranscription, targetApplication: pendingInsertionTargetApplication)
        } catch {
            transcriptionState = .idle
            setPreservedStatusMessage("Could not transcribe the recording locally. \(error.localizedDescription)")
            showMainWindow()
        }
    }

    private func refinedTranscriptionIfNeeded(_ transcription: WhisperTranscriptionResult) async -> WhisperTranscriptionResult {
        guard refinementConfiguration.isEnabled else {
            return transcription
        }

        let model = refinementConfiguration.model

        guard isRefinementModelSupported(model) else {
            setPreservedStatusMessage("Could not refine the transcript locally, so DictaFlow will use the raw Whisper text. \(unsupportedRefinementModelMessage(for: model))")
            showMainWindow()
            updateStatusMessage()
            return transcription
        }

        guard let modelURL = modelDownloadService.preparedRefinementModelURL(for: model) else {
            refinementConfiguration.isEnabled = false
            persistRefinementConfiguration()
            setPreservedStatusMessage("Refinement was turned off because \(model.displayName) is not prepared. DictaFlow will use the raw Whisper text.")
            showMainWindow()
            updateStatusMessage()
            return transcription
        }

        do {
            transcriptionState = .refining(model)
            updateStatusMessage()

            let refinement = try await transcriptRefinementService.refine(
                transcript: transcription.text,
                whisperTaskMode: transcription.taskMode,
                modelURL: modelURL,
                configuration: refinementConfiguration
            )

            var refinedTranscription = transcription
            refinedTranscription.refinement = refinement
            lastTranscription = refinedTranscription
            transcriptionState = .idle
            clearPreservedStatusMessage()
            updateStatusMessage()
            return refinedTranscription
        } catch {
            transcriptionState = .idle
            setPreservedStatusMessage("Could not refine the transcript locally, so DictaFlow will use the raw Whisper text. \(error.localizedDescription)")
            showMainWindow()
            updateStatusMessage()
            return transcription
        }
    }

    private func insert(transcription: WhisperTranscriptionResult, targetApplication: InsertionTargetApplication?) async {
        let text = transcription.insertionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            pendingInsertionTargetApplication = nil
            setPreservedStatusMessage("Whisper returned an empty transcript, so there was nothing to insert.")
            showMainWindow()
            return
        }

        let resolvedTargetApplication = targetApplication ?? captureCurrentInsertionTargetApplication()
        let targetApplicationName = resolvedTargetApplication?.displayName

        ensureAccessibilityPermissionForInsertion(targetApplicationName: targetApplicationName)
        let canAttemptAutomaticInsertion = accessibilityPermissionState == .granted

        textInsertionState = .inserting(targetApplicationName: targetApplicationName)
        updateStatusMessage()

        let insertionResult = await textInsertionService.insertText(
            text,
            targetApplication: resolvedTargetApplication,
            allowAccessibilityFeatures: canAttemptAutomaticInsertion
        )

        lastTextInsertion = insertionResult
        textInsertionState = .idle
        pendingInsertionTargetApplication = nil

        if insertionResult.method == .copyPanel, !canAttemptAutomaticInsertion {
            setPreservedStatusMessage("Accessibility access is required for automatic insertion. The latest transcript was copied to the clipboard.")
        } else {
            clearPreservedStatusMessage()
        }

        updateStatusMessage()
    }

    private func ensureAccessibilityPermissionForInsertion(targetApplicationName: String?) {
        accessibilityPermissionState = resolvedAccessibilityPermissionState()

        guard accessibilityPermissionState == .undetermined else {
            return
        }

        textInsertionState = .requestingAccessibilityPermission(targetApplicationName: targetApplicationName)
        updateStatusMessage()
        settingsStore.markAccessibilityPermissionRequested()
        _ = permissionService.requestAccessibilityPermission()
        accessibilityPermissionState = resolvedAccessibilityPermissionState()
    }

    private func resolvedAccessibilityPermissionState() -> AccessibilityPermissionState {
        AccessibilityPermissionState(
            isGranted: permissionService.isAccessibilityPermissionGranted(),
            hasRequestedBefore: settingsStore.hasRequestedAccessibilityPermission
        )
    }

    private func setPreservedStatusMessage(_ message: String) {
        preservedStatusMessage = message
        statusMessage = message
    }

    private func clearPreservedStatusMessage() {
        preservedStatusMessage = nil
    }

    private func configureWorkspaceObservers() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { notification in
                notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            }
            .compactMap(Self.makeInsertionTargetApplication(from:))
            .sink { [weak self] targetApplication in
                self?.lastKnownExternalTargetApplication = targetApplication
            }
            .store(in: &workspaceObservers)
    }

    private func captureCurrentInsertionTargetApplication() -> InsertionTargetApplication? {
        if let currentTargetApplication = Self.makeInsertionTargetApplication(from: NSWorkspace.shared.frontmostApplication) {
            lastKnownExternalTargetApplication = currentTargetApplication
            return currentTargetApplication
        }

        return lastKnownExternalTargetApplication
    }

    private static func makeInsertionTargetApplication(from application: NSRunningApplication?) -> InsertionTargetApplication? {
        guard let application else {
            return nil
        }

        guard application.activationPolicy == .regular else {
            return nil
        }

        guard application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }

        return InsertionTargetApplication(
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName,
            processIdentifier: application.processIdentifier
        )
    }

    private func updateStatusMessage() {
        switch recordingState {
        case .requestingPermission:
            statusMessage = "DictaFlow is requesting microphone access before starting local dictation."
            return
        case .recording:
            statusMessage = "Recording locally to a temporary file. Press \(hotkeyDisplayText) again to stop."
            return
        case .stopping:
            statusMessage = "Stopping recording and finalizing the temporary audio file."
            return
        case .idle:
            break
        }

        switch transcriptionState {
        case .idle:
            break
        case .preparingModel(let model):
            statusMessage = "Preparing the local \(model.displayName) Whisper model in Application Support."
            return
        case .downloadingModel(let model, _):
            statusMessage = modelDownloadProgressText ?? "Downloading the local \(model.displayName) Whisper model."
            return
        case .transcribing(let model):
            statusMessage = "Running local \(model.displayName) Whisper transcription on the last recorded clip."
            return
        case .preparingRefinementModel(let model):
            statusMessage = "Preparing the local \(model.displayName) refinement model in Application Support."
            return
        case .downloadingRefinementModel(let model, _):
            statusMessage = modelDownloadProgressText ?? "Downloading the local \(model.displayName) refinement model."
            return
        case .refining(let model):
            statusMessage = "Refining the latest transcript locally with \(model.displayName)."
            return
        }

        switch textInsertionState {
        case .idle:
            break
        case .requestingAccessibilityPermission(let targetApplicationName):
            statusMessage = "DictaFlow is requesting Accessibility permission before inserting into \(targetApplicationName ?? "the target app")."
            return
        case .inserting(let targetApplicationName):
            statusMessage = "Inserting the latest transcript into \(targetApplicationName ?? "the focused app")."
            return
        }

        if let preservedStatusMessage {
            statusMessage = preservedStatusMessage
            return
        }

        if microphonePermissionState == .denied || microphonePermissionState == .restricted {
            statusMessage = microphonePermissionState.detailText
            return
        }

        if let lastTextInsertion {
            if lastTextInsertion.method == .copyPanel, accessibilityPermissionState != .granted {
                statusMessage = "Accessibility access is still required for automatic insertion. The latest transcript was copied for manual paste."
            } else {
                statusMessage = lastTextInsertion.summaryText
            }
            return
        }

        if accessibilityPermissionState == .denied {
            statusMessage = accessibilityPermissionState.detailText
            return
        }

        if let lastTranscription, !lastTranscription.insertionText.isEmpty {
            if lastTranscription.refinement != nil {
                statusMessage = "Last transcription was refined locally and is ready for insertion."
            } else {
                statusMessage = "Last transcription finished at \(lastTranscription.completedAt.formatted(date: .omitted, time: .standard)) and is ready for insertion."
            }
            return
        }

        if let lastCapture {
            statusMessage = "Last capture saved to \(lastCapture.fileURL.path) and is ready for local Whisper transcription."
            return
        }

        if !isHotkeyRegistered {
            statusMessage = "DictaFlow could not register the global shortcut. Open the app window to troubleshoot."
            return
        }

        if isMainWindowVisible {
            statusMessage = "Window is active. Press \(hotkeyDisplayText) or use the button below to start a local recording."
            return
        }

        switch launchExperience {
        case .firstLaunch:
            statusMessage = "First-launch session. DictaFlow is preparing its local Whisper model for offline use."
        case .returningUser:
            statusMessage = "DictaFlow is ready in the menu bar. Press \(hotkeyDisplayText) to start recording."
        }
    }
}
