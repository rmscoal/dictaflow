import AppKit
import Combine
import Foundation

@MainActor
protocol MainWindowRouting: AnyObject {
    func showMainWindow()
    func closeMainWindow()
}

@MainActor
final class DictaFlowAppState: ObservableObject {
    @Published private(set) var isMainWindowVisible = false
    @Published private(set) var microphonePermissionState: MicrophonePermissionState
    @Published private(set) var recordingState: DictationRecordingState
    @Published private(set) var transcriptionState: TranscriptionPipelineState
    @Published private(set) var lastCapture: DictationCapture?
    @Published private(set) var lastTranscription: WhisperTranscriptionResult?
    @Published private(set) var statusMessage: String
    @Published private(set) var isHotkeyRegistered = false
    @Published private(set) var modelDownloadProgressText: String?

    let launchExperience: AppLaunchExperience
    let whisperConfiguration: WhisperConfiguration

    private let settingsStore: SettingsStoreProtocol
    private let permissionService: PermissionServiceProtocol
    private let audioRecorderService: AudioRecorderServiceProtocol
    private let hotkeyService: HotkeyServiceProtocol
    private let modelDownloadService: ModelDownloadServiceProtocol
    private let whisperService: WhisperServiceProtocol
    private weak var mainWindowRouter: MainWindowRouting?

    convenience init() {
        self.init(
            settingsStore: UserDefaultsSettingsStore(),
            permissionService: SystemPermissionService(),
            audioRecorderService: SystemAudioRecorderService(),
            hotkeyService: CarbonHotkeyService(),
            modelDownloadService: WhisperModelDownloadService(),
            whisperService: WhisperCPPService()
        )
    }

    init(
        settingsStore: SettingsStoreProtocol,
        permissionService: PermissionServiceProtocol,
        audioRecorderService: AudioRecorderServiceProtocol,
        hotkeyService: HotkeyServiceProtocol,
        modelDownloadService: ModelDownloadServiceProtocol,
        whisperService: WhisperServiceProtocol
    ) {
        self.settingsStore = settingsStore
        self.permissionService = permissionService
        self.audioRecorderService = audioRecorderService
        self.hotkeyService = hotkeyService
        self.modelDownloadService = modelDownloadService
        self.whisperService = whisperService
        self.launchExperience = settingsStore.shouldShowMainWindowOnLaunch ? .firstLaunch : .returningUser
        self.whisperConfiguration = .default
        self.microphonePermissionState = permissionService.currentMicrophonePermissionStatus()
        self.recordingState = .idle
        self.transcriptionState = .idle
        self.lastCapture = nil
        self.lastTranscription = nil
        self.statusMessage = ""
        self.modelDownloadProgressText = nil
        updateStatusMessage()
    }

    var menuBarIconName: String {
        if recordingState.isRecording {
            return "mic.circle.fill"
        }

        if transcriptionState.isTranscribing {
            return "waveform.badge.magnifyingglass"
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
        }

        if recordingState.isRecording {
            return "Recording in progress"
        }

        return isMainWindowVisible ? "Main window open" : "Running in menu bar"
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

        if transcriptionState.isTranscribing {
            return "waveform.badge.magnifyingglass"
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
            return "Ready to record, transcribe locally with Whisper, and prepare for text insertion."
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
        }
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
        }
    }

    func attach(mainWindowRouter: MainWindowRouting) {
        self.mainWindowRouter = mainWindowRouter
    }

    func handleApplicationLaunch() {
        refreshMicrophonePermissionStatus()
        registerGlobalHotkey()
        prepareDefaultModelIfNeeded()

        if launchExperience == .firstLaunch {
            showMainWindow()
            settingsStore.markInitialWindowPresentationComplete()
        }

        updateStatusMessage()
    }

    func showMainWindow() {
        mainWindowRouter?.showMainWindow()
    }

    func closeMainWindow() {
        mainWindowRouter?.closeMainWindow()
    }

    func toggleMainWindow() {
        isMainWindowVisible ? closeMainWindow() : showMainWindow()
    }

    func refreshMicrophonePermissionStatus() {
        microphonePermissionState = permissionService.currentMicrophonePermissionStatus()
        updateStatusMessage()
    }

    func retryModelPreparation() {
        prepareDefaultModelIfNeeded()
    }

    func toggleDictation() {
        Task { @MainActor [weak self] in
            await self?.performDictationToggle()
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

    private func registerGlobalHotkey() {
        do {
            try hotkeyService.registerToggleHotkey { [weak self] in
                self?.toggleDictation()
            }
            isHotkeyRegistered = true
        } catch {
            isHotkeyRegistered = false
            statusMessage = error.localizedDescription
            showMainWindow()
        }
    }

    private func prepareDefaultModelIfNeeded() {
        guard !recordingState.isRecording, !transcriptionState.isPreparingModel, !transcriptionState.isTranscribing else {
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
                    self.statusMessage = "Could not prepare the Whisper model. \(error.localizedDescription)"
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

    private func formattedModelProgress(bytesWritten: Int64, totalBytes: Int64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        let writtenText = formatter.string(fromByteCount: bytesWritten)

        if let totalBytes, totalBytes > 0 {
            let totalText = formatter.string(fromByteCount: totalBytes)
            return "Downloading \(whisperConfiguration.model.displayName) model: \(writtenText) of \(totalText)"
        }

        return "Downloading \(whisperConfiguration.model.displayName) model: \(writtenText)"
    }

    private func performDictationToggle() async {
        if transcriptionState.isTranscribing {
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
            statusMessage = "Could not start recording. \(error.localizedDescription)"
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
            statusMessage = "Could not stop recording cleanly. \(error.localizedDescription)"
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
            transcriptionState = .idle
            updateStatusMessage()
        } catch {
            transcriptionState = .idle
            statusMessage = "Could not transcribe the recording locally. \(error.localizedDescription)"
            showMainWindow()
        }
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
        }

        if microphonePermissionState == .denied || microphonePermissionState == .restricted {
            statusMessage = microphonePermissionState.detailText
            return
        }

        if let lastTranscription, !lastTranscription.text.isEmpty {
            statusMessage = "Last transcription finished at \(lastTranscription.completedAt.formatted(date: .omitted, time: .standard)) using the \(lastTranscription.model.displayName) model."
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
