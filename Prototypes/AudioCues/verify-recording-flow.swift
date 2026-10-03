// Mock-only coordinator checks. No microphone, playback, clipboard, or system volume changes.
import Foundation

@MainActor
final class Boundaries: PermissionServiceProtocol, AudioRecorderServiceProtocol,
    AudioOutputVolumeServiceProtocol, HotkeyServiceProtocol, ModelDownloadServiceProtocol,
    WhisperServiceProtocol, TranscriptRefinementServiceProtocol, RefinementPromptStoreProtocol,
    TextInsertionServiceProtocol, LocalNotificationServiceProtocol, AppUpdateChecking, RecordingOverlayRouting {
    var events: [String] = []
    var isRecording = false
    var currentPowerLevel: Double { 0 }
    var recordingError: Error?
    var failStart = false
    var holdPreparation = false
    var preparationWait: CheckedContinuation<Void, Never>?
    var overlay: RecordingOverlayPresentation?
    func updateOverlay(_ presentation: RecordingOverlayPresentation?, cancelAction: @escaping () -> Void) { overlay = presentation }
    func shutdown() { isRecording = false; events.append("capture-discard") }
    func completePreparation() { let wait = preparationWait; preparationWait = nil; wait?.resume() }
    var holdDucking = false
    var duckingWait: CheckedContinuation<Void, Never>?
    var isDucked = false
    let modelsDirectoryURL = URL(fileURLWithPath: "/tmp/dictaflow-cue-checks-models")
    var promptsDirectoryURL: URL { modelsDirectoryURL }
    let captureURL = URL(fileURLWithPath: "/tmp/dictaflow-cue-checks-recording.m4a")

    func currentMicrophonePermissionStatus() -> MicrophonePermissionState { .granted }
    func requestMicrophonePermissionIfNeeded() async -> MicrophonePermissionState { .granted }
    func isAccessibilityPermissionGranted() -> Bool { true }
    func requestAccessibilityPermission() -> Bool { true }
    func openMicrophoneSettings() { fatalError("No system UI allowed") }
    func openAccessibilitySettings() { fatalError("No system UI allowed") }
    func prepareRecording() async throws {
        events.append("prepare")
        if holdPreparation { await withCheckedContinuation { preparationWait = $0 } }
    }
    func startRecording() async throws -> URL {
        if failStart { throw AudioRecorderServiceError.failedToStart }
        isRecording = true
        events.append("capture-start")
        return captureURL
    }
    func stopRecording() async throws -> DictationCapture {
        isRecording = false
        events.append("capture-stop")
        return DictationCapture(fileURL: captureURL, duration: 1, capturedAt: Date())
    }
    func discardRecording() throws {
        isRecording = false
        events.append("capture-discard")
    }
    func beginDucking() async throws {
        events.append("duck-begin")
        if holdDucking {
            await withCheckedContinuation { duckingWait = $0 }
        }
        isDucked = true
        events.append("duck-finished")
    }
    func completeDucking() {
        let continuation = duckingWait
        duckingWait = nil
        continuation?.resume()
    }
    func restoreDucking() async throws {
        isDucked = false
        events.append("restore")
    }
    func restoreDuckingForTermination() throws { isDucked = false }
    func registerToggleHotkey(_ shortcut: GlobalShortcutDescriptor, handler: @escaping () -> Void) throws {}
    func unregisterToggleHotkey() {}
    func installedModelFiles() -> [LocalModelFile] { [] }
    func deleteModelFiles(_ files: [LocalModelFile]) async throws -> Int64 { 0 }
    func cancelDownload(modelIdentifier: String) {}
    func removeIncompleteDownloads() -> Int64 { 0 }
    func ensureModelAvailable(_ model: WhisperModelDescriptor, progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void) async throws -> URL { modelsDirectoryURL }
    func ensureRefinementModelAvailable(_ model: RefinementModelDescriptor, progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void) async throws -> URL { modelsDirectoryURL }
    func isWhisperModelPrepared(_ model: WhisperModelDescriptor) -> Bool { true }
    func verifiedWhisperModelURL(for model: WhisperModelDescriptor) async -> URL? { modelsDirectoryURL }
    func isWhisperEncoderPrepared(_ model: WhisperModelDescriptor) -> Bool { false }
    func isWhisperEncoderDownloaded(_ model: WhisperModelDescriptor) -> Bool { false }
    func setWhisperEncoderEnabled(_ enabled: Bool, for model: WhisperModelDescriptor) async throws {}
    func removeOrphanedEncoders() -> Int64 { 0 }
    func ensureWhisperEncoderAvailable(_ model: WhisperModelDescriptor, progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void) async throws -> URL { modelsDirectoryURL }
    func deleteWhisperEncoder(_ model: WhisperModelDescriptor) async throws -> Int64 { 0 }
    func isRefinementModelPrepared(_ model: RefinementModelDescriptor) -> Bool { true }
    func verifiedRefinementModelURL(for model: RefinementModelDescriptor) async -> URL? { modelsDirectoryURL }
    func transcribe(audioFileURL: URL, modelURL: URL, configuration: WhisperConfiguration) async throws -> WhisperTranscriptionResult {
        WhisperTranscriptionResult(text: "Test", segments: [], detectedLanguageCode: nil,
            model: configuration.model, taskMode: configuration.taskMode, completedAt: Date())
    }
    func prepare(modelURL: URL) async throws {}
    func unloadModel() async {}
    func isRuntimeAvailable() async -> Bool { true }
    func reloadModels() async {}
    func stop() async {}
    func refine(transcript: String, whisperTaskMode: WhisperTaskMode, modelURL: URL,
        configuration: RefinementConfiguration, promptTemplate: String) async throws -> TranscriptRefinementResult {
        fatalError("Refinement is disabled in these checks")
    }
    func promptTemplate() -> String { "Test" }
    func hasCustomPromptTemplate() -> Bool { false }
    func savePromptTemplate(_ template: String) throws {}
    func resetPromptTemplate() throws {}
    func insertText(_ text: String, targetApplication: InsertionTargetApplication?, allowAccessibilityFeatures: Bool) async -> TextInsertionResult {
        events.append("insert")
        return TextInsertionResult(text: text, method: .accessibilityDirect,
            targetApplicationName: nil, completedAt: Date(), isInsertionConfirmed: true)
    }
    func copyTextToPasteboard(_ text: String) { fatalError("No clipboard writes allowed") }
    func requestAuthorizationIfNeeded() {}
    func show(title: String, body: String) {}
    func latestRelease() async throws -> AppRelease { throw AppUpdateCheckError.noPublishedRelease }
}

@MainActor
final class SilentCues: SoundCueServiceProtocol {
    let boundaries: Boundaries
    var waiting: CheckedContinuation<Void, Error>?
    var played: [SoundCue] = []
    var failPlayback = false
    init(_ boundaries: Boundaries) { self.boundaries = boundaries }
    func play(_ cue: SoundCue, style: SoundCueStyle) async throws {
        played.append(cue)
        if cue == .startRecording {
            precondition(boundaries.isRecording, "Cue started before capture")
            boundaries.events.append("cue-start")
            if failPlayback { throw SoundCueServiceError.playbackFailed }
            try await withCheckedThrowingContinuation { waiting = $0 }
            boundaries.events.append("cue-finished")
        }
    }
    func stop() { complete() }
    func complete() {
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }
}

@MainActor
final class Fixture {
    let domain = "com.dictaflow.recording-flow-checks.\(UUID().uuidString)"
    let boundaries = Boundaries()
    let cues: SilentCues
    let state: DictaFlowAppState
    init(enabled: Bool = true) {
        let settings = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: domain)!)
        settings.saveSoundCuesEnabled(enabled)
        settings.saveRecordingPlaybackBehavior(.lowerSystemVolume)
        cues = SilentCues(boundaries)
        state = DictaFlowAppState(settingsStore: settings, permissionService: boundaries,
            audioRecorderService: boundaries, audioOutputVolumeService: boundaries, soundCueService: cues,
            hotkeyService: boundaries, modelDownloadService: boundaries, whisperService: boundaries,
            transcriptRefinementService: boundaries, refinementPromptStore: boundaries,
            textInsertionService: boundaries, localNotificationService: boundaries, appUpdateService: boundaries)
        state.attach(recordingOverlayRouter: boundaries)
    }
    func cleanup() {
        state.prepareForTermination()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
    }
}

@main
struct RecordingFlowChecks {
    @MainActor
    static func main() async throws {
        do {
            let f = Fixture(); defer { f.cleanup() }
            f.boundaries.holdPreparation = true
            f.state.toggleDictation()
            await wait { f.boundaries.preparationWait != nil }
            precondition(f.state.recordingState == .starting)
            precondition(f.boundaries.overlay?.phase == .starting && f.boundaries.overlay?.isCancellable == true,
                         "Blocked hardware initialization hid or locked the pill")
            precondition(!f.boundaries.isRecording && f.cues.played.isEmpty)
            let cancel = Task { await f.state.cancelRecording() }
            await wait { f.state.recordingState == .stopping }
            precondition(f.boundaries.overlay == nil, "Cancellation waited for hardware before hiding the pill")
            f.boundaries.completePreparation()
            await cancel.value
            precondition(f.state.recordingState == .idle && f.boundaries.overlay == nil)
            precondition(!f.boundaries.events.contains("capture-start"), "Cancelled startup still opened the microphone")
            precondition(f.state.recordingFailureMessage == nil)
            precondition(f.cues.played.isEmpty && !f.boundaries.isDucked)
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            f.state.toggleDictation()
            await wait { f.cues.waiting != nil }
            precondition(f.state.recordingState.isRecording, "Capture waited for cue completion")
            precondition(!f.boundaries.isDucked, "Volume dropped during start cue")
            f.cues.complete()
            await wait { f.boundaries.isDucked }
            f.state.toggleDictation()
            await wait { f.boundaries.events.contains("insert") }
            precondition(!f.boundaries.isDucked)
            await wait { f.cues.played.contains(.stopRecording) }
            precondition(f.cues.played == [.startRecording, .stopRecording], "Unexpected cue after insertion")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            f.state.toggleDictation()
            await wait { f.cues.waiting != nil }
            f.state.toggleDictation()
            await wait { f.boundaries.events.contains("insert") }
            precondition(!f.boundaries.events.contains("duck-begin"), "Late duck after quick stop")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            f.state.toggleDictation()
            await wait { f.cues.waiting != nil }
            await f.state.cancelRecording()
            precondition(f.state.recordingState == .idle)
            precondition(!f.boundaries.events.contains("duck-begin"), "Late duck after cancel")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            f.state.toggleDictation()
            await wait { f.cues.waiting != nil }
            f.state.updateSoundCuesEnabled(false)
            await wait { f.boundaries.isDucked }
            precondition(f.state.recordingState.isRecording, "Mute interrupted recording")
            await f.state.cancelRecording()
            precondition(!f.boundaries.isDucked)
        }
        do {
            let f = Fixture(enabled: false); defer { f.cleanup() }
            f.state.toggleDictation()
            await wait { f.boundaries.isDucked }
            precondition(f.cues.played.isEmpty)
            await f.state.cancelRecording()
            precondition(!f.boundaries.isDucked)
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            f.boundaries.holdDucking = true
            f.state.toggleDictation()
            await wait { f.cues.waiting != nil }
            f.cues.complete()
            await wait { f.boundaries.duckingWait != nil }
            let cancel = Task { await f.state.cancelRecording() }
            await wait { !f.boundaries.isRecording }
            precondition(!f.boundaries.events.contains("restore"), "Restored before pending volume change")
            f.boundaries.completeDucking()
            await cancel.value
            precondition(!f.boundaries.isDucked, "Pending duck overwrote restoration")
            precondition(f.boundaries.events.firstIndex(of: "duck-finished")! < f.boundaries.events.firstIndex(of: "restore")!)
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            f.cues.failPlayback = true
            f.state.toggleDictation()
            await wait { f.boundaries.isDucked }
            precondition(f.state.recordingState.isRecording && f.state.soundCuePlaybackMessage != nil)
            await f.state.cancelRecording()
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            f.boundaries.failStart = true
            f.state.toggleDictation()
            await wait { f.boundaries.events.contains("capture-discard") }
            await wait { f.state.recordingState == .idle }
            precondition(f.cues.played.isEmpty && !f.boundaries.events.contains("duck-begin"))
            precondition(f.state.recordingFailureMessage?.contains("Could not start recording") == true,
                         "Start failure was not available to the error alert")
            f.state.dismissRecordingFailure()
            precondition(f.state.recordingFailureMessage == nil, "Dismissed alert retained its error")
            f.boundaries.failStart = false
            f.state.toggleDictation()
            await wait { f.boundaries.isRecording }
            precondition(f.state.recordingFailureMessage == nil, "Retry retained the previous error")
            await f.state.cancelRecording()
        }
        do {
            let f = Fixture(enabled: false); defer { f.cleanup() }
            f.state.toggleDictation()
            await wait { f.boundaries.isDucked }
            f.boundaries.recordingError = AudioRecorderServiceError.audioDeviceChanged
            for _ in 0..<10 {
                pumpTimers()
                try await Task.sleep(for: .milliseconds(10))
                if f.state.recordingState == .idle { break }
            }
            precondition(f.state.recordingState == .idle, "Device failure left recording active")
            precondition(!f.boundaries.isDucked && !f.boundaries.isRecording)
            precondition(f.boundaries.events.contains("capture-discard"))
            precondition(!f.boundaries.events.contains("insert"), "Incomplete capture was inserted")
            precondition(f.state.statusMessage.contains("audio device changed"))
            precondition(f.state.recordingFailureMessage?.contains("audio device changed") == true,
                         "Interrupted capture did not surface the error alert")
            precondition(f.cues.played.isEmpty, "Recording failure played a processing error cue")
        }
        do {
            let f = Fixture(); defer { f.cleanup() }
            f.state.toggleDictation()
            await wait { f.cues.waiting != nil }
            f.state.prepareForTermination()
            precondition(!f.boundaries.isRecording && !f.boundaries.isDucked,
                         "Quit left the audio engine or volume adjustment active")
        }
        print("Passed: responsive/cancellable startup, capture/cue overlap, deferred lowering, quick stop/cancel, mute, cues off, in-flight duck restoration, playback/start failure, device interruption, and quit cleanup. No recording, playback, or system-volume changes occurred.")
    }
    @MainActor
    static func pumpTimers() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    @MainActor
    static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Recording flow check timed out")
    }
}
