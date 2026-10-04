import Combine
import Foundation
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class RecordingStartupTests: XCTestCase {
    func testEmptyTranscriptSkipsRefinementAndInsertion() async throws {
        let whisper = PipelineWhisperService()
        let refinement = PipelineRefinementService()
        let fixture = try RecordingStartupFixture(whisper: whisper, refinement: refinement, usePipelineModels: true)
        defer { fixture.cleanup() }
        fixture.volume.shouldWait = false

        let recording = expectation(description: "Recording starts")
        let recordingObservation = fixture.state.$recordingState.sink {
            if $0.isRecording { recording.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [recording], timeout: 2)
        recordingObservation.cancel()

        let completed = expectation(description: "No-speech result completes without insertion")
        let completedObservation = fixture.state.$statusMessage.sink {
            if $0 == "No speech was detected, so there was nothing to insert." { completed.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [completed], timeout: 2)
        completedObservation.cancel()
        let refinementCalls = await refinement.refineCalls
        XCTAssertEqual(refinementCalls, 0)
        XCTAssertEqual(fixture.state.lastTranscription?.refinementStatus, .skipped(reason: "No speech was detected."))
        XCTAssertNil(fixture.state.lastTextInsertion)
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertEqual(fixture.state.transcriptionState, .idle)
        // StartupInsertionService also fails on any insertion or clipboard write.
    }

    func testEncoderDownloadUsesDedicatedWarmupInsteadOfTranscription() async throws {
        let warmed = expectation(description: "Encoder warmup is called")
        let whisper = PipelineWhisperService(onWarmup: { warmed.fulfill() })
        let fixture = try RecordingStartupFixture(whisper: whisper, usePipelineModels: true)
        defer { fixture.cleanup() }
        fixture.state.downloadWhisperEncoder(fixture.state.whisperConfiguration.model)
        await fulfillment(of: [warmed], timeout: 2)
        let transcriptionCalls = await whisper.transcribeCalls
        XCTAssertEqual(transcriptionCalls, 0)
    }

    func testEmptyTranscriptPreservesOnboardingNoSpeechResult() async throws {
        let refinement = PipelineRefinementService()
        let fixture = try RecordingStartupFixture(whisper: PipelineWhisperService(), refinement: refinement, usePipelineModels: true)
        defer { fixture.cleanup() }
        fixture.volume.shouldWait = false
        fixture.permissions.accessibilityGranted = true
        fixture.state.handleApplicationLaunch()
        fixture.state.advanceOnboarding() // Welcome to permissions.
        fixture.state.advanceOnboarding() // Permissions to model preparation.
        fixture.state.advanceOnboarding() // Prepared model to shortcut practice.
        XCTAssertEqual(fixture.state.onboardingPresentation?.step, .shortcut)

        let recording = expectation(description: "Practice recording starts")
        let recordingObservation = fixture.state.$recordingState.sink {
            if $0.isRecording { recording.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [recording], timeout: 2)
        recordingObservation.cancel()
        let completed = expectation(description: "Practice returns no speech")
        let completedObservation = fixture.state.$onboardingPracticeResult.sink {
            if $0 == .noSpeech { completed.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [completed], timeout: 2)
        completedObservation.cancel()
        let refinementCalls = await refinement.refineCalls
        XCTAssertEqual(refinementCalls, 0)
        XCTAssertNil(fixture.state.lastTextInsertion)
        XCTAssertNil(fixture.overlay.presentation)
        XCTAssertEqual(fixture.state.transcriptionState, .idle)
    }

    func testRepeatedToggleDuringDuckingStartsOnlyOneRecorderAndCanStop() async throws {
        let fixture = try RecordingStartupFixture()
        defer { fixture.cleanup() }
        let ducking = expectation(description: "Ducking is waiting")
        fixture.volume.onBegin = { ducking.fulfill() }
        fixture.state.toggleDictation()
        await fulfillment(of: [ducking], timeout: 2)

        XCTAssertEqual(fixture.state.recordingState, .starting)
        XCTAssertTrue(fixture.state.whisperSettingsLocked)
        XCTAssertTrue(fixture.state.isDictationActionDisabled)
        XCTAssertEqual(fixture.overlay.presentation?.phase, .starting)
        fixture.state.toggleDictation()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.volume.beginCalls, 1)
        XCTAssertEqual(fixture.recorder.startCalls, 0)

        let recording = expectation(description: "Recording starts")
        let observation = fixture.state.$recordingState.sink {
            if $0.isRecording { recording.fulfill() }
        }
        fixture.volume.resume()
        await fulfillment(of: [recording], timeout: 2)
        observation.cancel()
        XCTAssertEqual(fixture.recorder.startCalls, 1)
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.state.isDictationActionDisabled)
        XCTAssertEqual(fixture.overlay.presentation?.phase, .recording)

        let stopped = expectation(description: "The next toggle stops recording")
        fixture.recorder.onStop = { stopped.fulfill() }
        fixture.state.toggleDictation()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(fixture.recorder.stopCalls, 1)
        XCTAssertFalse(fixture.recorder.isRecording)
    }

    func testRepeatedToggleWhileRecorderStartsDoesNotResetTheSession() async throws {
        let fixture = try RecordingStartupFixture()
        defer { fixture.cleanup() }
        fixture.volume.shouldWait = false
        fixture.recorder.shouldWait = true
        let starting = expectation(description: "Recorder start is waiting")
        fixture.recorder.onStart = { starting.fulfill() }
        fixture.state.toggleDictation()
        await fulfillment(of: [starting], timeout: 2)
        fixture.state.toggleDictation()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.recorder.startCalls, 1)
        XCTAssertEqual(fixture.state.recordingState, .starting)

        let recording = expectation(description: "Recorder start finishes")
        let observation = fixture.state.$recordingState.sink {
            if $0.isRecording { recording.fulfill() }
        }
        fixture.recorder.resume()
        await fulfillment(of: [recording], timeout: 2)
        observation.cancel()
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertTrue(fixture.state.recordingState.isRecording)
        await fixture.state.cancelRecording()
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertEqual(fixture.state.recordingState, .idle)
    }

    func testPermissionDenialAndStartFailureAllowRetry() async throws {
        let fixture = try RecordingStartupFixture(permission: .denied)
        defer { fixture.cleanup() }
        let denied = expectation(description: "Permission denial returns to idle")
        var sawRequest = false
        let deniedObservation = fixture.state.$recordingState.sink {
            if $0 == .requestingPermission { sawRequest = true }
            if sawRequest && $0 == .idle { denied.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [denied], timeout: 2)
        deniedObservation.cancel()
        XCTAssertEqual(fixture.recorder.startCalls, 0)
        XCTAssertEqual(fixture.volume.beginCalls, 0)
        XCTAssertNil(fixture.overlay.presentation)

        fixture.permissions.permission = .granted
        fixture.volume.shouldWait = false
        fixture.recorder.failNextStart = true
        let failed = expectation(description: "Start failure returns to idle")
        var sawStarting = false
        let failedObservation = fixture.state.$recordingState.sink {
            if $0 == .starting { sawStarting = true }
            if sawStarting && $0 == .idle { failed.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [failed], timeout: 2)
        failedObservation.cancel()
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertFalse(fixture.state.isDictationActionDisabled)
        XCTAssertNil(fixture.overlay.presentation)

        let recording = expectation(description: "Retry starts recording")
        let recordingObservation = fixture.state.$recordingState.sink {
            if $0.isRecording { recording.fulfill() }
        }
        fixture.state.toggleDictation()
        await fulfillment(of: [recording], timeout: 2)
        recordingObservation.cancel()
        XCTAssertEqual(fixture.recorder.startCalls, 2)
        XCTAssertTrue(fixture.recorder.isRecording)
        await fixture.state.cancelRecording()
        XCTAssertEqual(fixture.state.recordingState, .idle)
    }
}

/// Uses the real coordinator with isolated settings and synthetic recording files.
@MainActor
private final class RecordingStartupFixture {
    let directory: URL
    let suiteName = "DictaFlowTests.\(UUID().uuidString)"
    let permissions: StartupPermissionService
    let volume = StartupVolumeService()
    let recorder: StartupRecorderService
    let overlay = StartupOverlayRouter()
    let state: DictaFlowAppState

    init(
        permission: MicrophonePermissionState = .granted,
        whisper: WhisperServiceProtocol = WhisperCPPService(),
        refinement: TranscriptRefinementServiceProtocol = LlamaCLITranscriptRefinementService(),
        usePipelineModels: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = UserDefaultsSettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        settings.saveAutomaticallyChecksForUpdates(false)
        settings.saveRecordingPlaybackBehavior(.lowerSystemVolume)
        var refinementConfiguration = RefinementConfiguration.default
        refinementConfiguration.isEnabled = usePipelineModels
        settings.saveRefinementConfiguration(refinementConfiguration)
        try Data("synthetic model".utf8).write(to: directory.appendingPathComponent(settings.whisperConfiguration.model.filename))
        permissions = StartupPermissionService(permission: permission)
        recorder = StartupRecorderService(fileURL: directory.appendingPathComponent("capture.m4a"))
        state = DictaFlowAppState(
            settingsStore: settings, permissionService: permissions,
            audioRecorderService: recorder, audioOutputVolumeService: volume,
            hotkeyService: StartupHotkeyService(),
            modelDownloadService: usePipelineModels
                ? PipelineModelDownloadService(modelsDirectoryURL: directory)
                : WhisperModelDownloadService(modelsDirectoryURL: directory),
            whisperService: whisper,
            transcriptRefinementService: refinement,
            refinementPromptStore: StartupPromptStore(directory: directory),
            textInsertionService: StartupInsertionService(),
            localNotificationService: StartupNotificationService(),
            appUpdateService: GitHubReleaseUpdateService()
        )
        state.attach(recordingOverlayRouter: overlay)
    }

    func cleanup() {
        state.prepareForTermination()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class StartupVolumeService: AudioOutputVolumeServiceProtocol {
    var shouldWait = true
    var beginCalls = 0
    var onBegin: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    func beginDucking() async throws {
        beginCalls += 1
        if shouldWait {
            await withCheckedContinuation { continuation = $0; onBegin?() }
        }
    }
    func resume() { continuation?.resume(); continuation = nil }
    func restoreDucking() async throws {}
    nonisolated func restoreDuckingForTermination() throws {}
}

@MainActor
private final class StartupRecorderService: AudioRecorderServiceProtocol {
    let fileURL: URL
    var isRecording = false
    var currentPowerLevel: Double { 0 }
    var startCalls = 0
    var stopCalls = 0
    var shouldWait = false
    var failNextStart = false
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    init(fileURL: URL) { self.fileURL = fileURL }
    func startRecording() async throws -> URL {
        startCalls += 1
        guard !isRecording else { throw AudioRecorderServiceError.alreadyRecording }
        if shouldWait {
            await withCheckedContinuation { continuation = $0; onStart?() }
        }
        if failNextStart { failNextStart = false; throw AudioRecorderServiceError.failedToStart }
        try Data().write(to: fileURL)
        isRecording = true
        return fileURL
    }
    func resume() { continuation?.resume(); continuation = nil }
    func stopRecording() async throws -> DictationCapture {
        stopCalls += 1
        isRecording = false
        onStop?()
        return DictationCapture(fileURL: fileURL, duration: 0, capturedAt: Date())
    }
    func discardRecording() throws {
        isRecording = false
        try FileManager.default.removeItem(at: fileURL)
    }
}

@MainActor
private final class StartupPermissionService: PermissionServiceProtocol {
    var permission: MicrophonePermissionState
    var accessibilityGranted = false
    init(permission: MicrophonePermissionState) { self.permission = permission }
    func currentMicrophonePermissionStatus() -> MicrophonePermissionState { permission }
    func requestMicrophonePermissionIfNeeded() async -> MicrophonePermissionState { permission }
    func isAccessibilityPermissionGranted() -> Bool { accessibilityGranted }
    func requestAccessibilityPermission() -> Bool { XCTFail("No insertion is expected"); return false }
    func openMicrophoneSettings() {}
    func openAccessibilitySettings() {}
}

@MainActor
private final class StartupHotkeyService: HotkeyServiceProtocol {
    func registerToggleHotkey(_ shortcut: GlobalShortcutDescriptor, handler: @escaping () -> Void) throws {}
    func unregisterToggleHotkey() {}
}

@MainActor
private final class StartupOverlayRouter: RecordingOverlayRouting {
    var presentation: RecordingOverlayPresentation?
    func updateOverlay(_ presentation: RecordingOverlayPresentation?, cancelAction: @escaping () -> Void) {
        self.presentation = presentation
    }
}

private final class StartupPromptStore: RefinementPromptStoreProtocol {
    let promptsDirectoryURL: URL
    init(directory: URL) { promptsDirectoryURL = directory }
    func promptTemplate() -> String { "" }
    func hasCustomPromptTemplate() -> Bool { false }
    func savePromptTemplate(_ template: String) throws {}
    func resetPromptTemplate() throws {}
}

@MainActor
private final class StartupInsertionService: TextInsertionServiceProtocol {
    func insertText(_ text: String, targetApplication: InsertionTargetApplication?, allowAccessibilityFeatures: Bool) async -> TextInsertionResult {
        XCTFail("No insertion is expected")
        return TextInsertionResult(text: text, method: .copyPanel, targetApplicationName: nil, completedAt: Date())
    }
    func copyTextToPasteboard(_ text: String) { XCTFail("No clipboard writes are expected") }
}

@MainActor
private final class StartupNotificationService: LocalNotificationServiceProtocol {
    func requestAuthorizationIfNeeded() {}
    func show(title: String, body: String) {}
}

private actor PipelineWhisperService: WhisperServiceProtocol {
    var transcribeCalls = 0
    let onWarmup: @Sendable () -> Void
    init(onWarmup: @escaping @Sendable () -> Void = {}) { self.onWarmup = onWarmup }
    func prepare(modelURL: URL) async throws {}
    func unloadModel() async {}
    func warmUpEncoder(audioFileURL: URL, modelURL: URL, configuration: WhisperConfiguration) async throws {
        onWarmup()
    }
    func transcribe(audioFileURL: URL, modelURL: URL, configuration: WhisperConfiguration) async throws -> WhisperTranscriptionResult {
        transcribeCalls += 1
        return WhisperTranscriptionResult(text: " \n", segments: [], detectedLanguageCode: nil,
            model: configuration.model, taskMode: configuration.taskMode, completedAt: Date())
    }
}

private actor PipelineRefinementService: TranscriptRefinementServiceProtocol {
    var refineCalls = 0
    func isRuntimeAvailable(for model: RefinementModelDescriptor) async -> Bool { true }
    func prepare(modelURL: URL) async throws {}
    func reloadModels() async {}
    func stop() async {}
    func refine(transcript: String, whisperTaskMode: WhisperTaskMode, modelURL: URL,
                configuration: RefinementConfiguration, promptTemplate: String) async throws -> TranscriptRefinementResult {
        refineCalls += 1
        XCTFail("An empty raw transcript must never reach refinement")
        return TranscriptRefinementResult(originalText: transcript, refinedText: "Invented text",
            model: configuration.model, mode: configuration.mode, completedAt: Date())
    }
}

/// Synthetic prepared models let coordinator tests reach inference without weights or downloads.
@MainActor
private final class PipelineModelDownloadService: ModelDownloadServiceProtocol {
    let modelsDirectoryURL: URL
    init(modelsDirectoryURL: URL) { self.modelsDirectoryURL = modelsDirectoryURL }
    func installedModelFiles() -> [LocalModelFile] { [] }
    func deleteModelFiles(_ files: [LocalModelFile]) async throws -> Int64 { 0 }
    func cancelDownload(modelIdentifier: String) {}
    func removeIncompleteDownloads() -> Int64 { 0 }
    func isWhisperModelPrepared(_ model: WhisperModelDescriptor) -> Bool { true }
    func verifiedWhisperModelURL(for model: WhisperModelDescriptor) async -> URL? {
        modelsDirectoryURL.appendingPathComponent(model.filename)
    }
    func ensureModelAvailable(_ model: WhisperModelDescriptor, progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void) async throws -> URL {
        modelsDirectoryURL.appendingPathComponent(model.filename)
    }
    func isWhisperEncoderPrepared(_ model: WhisperModelDescriptor) -> Bool { true }
    func isWhisperEncoderDownloaded(_ model: WhisperModelDescriptor) -> Bool { false }
    func setWhisperEncoderEnabled(_ enabled: Bool, for model: WhisperModelDescriptor) async throws {}
    func removeOrphanedEncoders() -> Int64 { 0 }
    func ensureWhisperEncoderAvailable(_ model: WhisperModelDescriptor, progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void) async throws -> URL {
        modelsDirectoryURL.appendingPathComponent(model.encoderDirectoryName)
    }
    func deleteWhisperEncoder(_ model: WhisperModelDescriptor) async throws -> Int64 { 0 }
    func isRefinementModelPrepared(_ model: RefinementModelDescriptor) -> Bool { true }
    func verifiedRefinementModelURL(for model: RefinementModelDescriptor) async -> URL? {
        modelsDirectoryURL.appendingPathComponent(model.filename)
    }
    func ensureRefinementModelAvailable(_ model: RefinementModelDescriptor, progressHandler: @escaping @Sendable (ModelDownloadEvent) -> Void) async throws -> URL {
        modelsDirectoryURL.appendingPathComponent(model.filename)
    }
}
