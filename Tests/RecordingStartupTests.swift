import Combine
import Foundation
import XCTest
@testable import DictaFlow_Dev

@MainActor
final class RecordingStartupTests: XCTestCase {
    func testRecordingStartsBeforeDuckingAndStopWaitsForVolumeRestoration() async throws {
        let fixture = try RecordingStartupFixture()
        defer { fixture.cleanup() }
        let ducking = expectation(description: "Ducking is waiting")
        fixture.volume.onBegin = { ducking.fulfill() }
        fixture.state.toggleDictation()
        await fulfillment(of: [ducking], timeout: 2)

        XCTAssertTrue(fixture.state.recordingState.isRecording)
        XCTAssertTrue(fixture.recorder.isRecording)
        XCTAssertEqual(fixture.recorder.startCalls, 1)
        XCTAssertFalse(fixture.state.isDictationActionDisabled)
        XCTAssertEqual(fixture.overlay.presentation?.phase, .recording)
        XCTAssertEqual(fixture.cues.played, [.startRecording])

        let stopped = expectation(description: "Capture stops while ducking is pending")
        fixture.recorder.onStop = { stopped.fulfill() }
        fixture.state.toggleDictation()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertEqual(fixture.volume.restoreCalls, 0)

        let restored = expectation(description: "Pending ducking finishes before restoration")
        fixture.volume.onRestore = { restored.fulfill() }
        fixture.volume.resume()
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertFalse(fixture.volume.isDucked)
        XCTAssertEqual(fixture.recorder.stopCalls, 1)
    }

    func testCancellationDuringPreparationHidesPillAndNeverStartsCapture() async throws {
        let fixture = try RecordingStartupFixture()
        defer { fixture.cleanup() }
        fixture.recorder.shouldWaitPreparation = true
        let preparing = expectation(description: "Audio preparation is waiting")
        fixture.recorder.onPrepare = { preparing.fulfill() }
        fixture.state.toggleDictation()
        await fulfillment(of: [preparing], timeout: 2)
        XCTAssertEqual(fixture.state.recordingState, .starting)
        XCTAssertTrue(fixture.overlay.presentation?.isCancellable == true)

        let stopping = expectation(description: "Cancellation reserves cleanup")
        let observation = fixture.state.$recordingState.sink {
            if $0 == .stopping { stopping.fulfill() }
        }
        let cancellation = Task { await fixture.state.cancelRecording() }
        await fulfillment(of: [stopping], timeout: 2)
        observation.cancel()
        XCTAssertNil(fixture.overlay.presentation)
        fixture.recorder.resumePreparation()
        await cancellation.value
        XCTAssertEqual(fixture.state.recordingState, .idle)
        XCTAssertEqual(fixture.recorder.startCalls, 0)
        XCTAssertEqual(fixture.volume.beginCalls, 0)
        XCTAssertTrue(fixture.cues.played.isEmpty)
        XCTAssertNil(fixture.state.recordingFailureMessage)
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
    let cues = StartupCueService()
    let state: DictaFlowAppState

    init(permission: MicrophonePermissionState = .granted) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = UserDefaultsSettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        settings.saveRecordingPlaybackBehavior(.lowerSystemVolume)
        settings.saveRefinementConfiguration(.default)
        try Data("synthetic model".utf8).write(to: directory.appendingPathComponent(settings.whisperConfiguration.model.filename))
        permissions = StartupPermissionService(permission: permission)
        recorder = StartupRecorderService(fileURL: directory.appendingPathComponent("capture.m4a"))
        state = DictaFlowAppState(
            settingsStore: settings, permissionService: permissions,
            audioRecorderService: recorder, audioOutputVolumeService: volume,
            soundCueService: cues,
            hotkeyService: CarbonHotkeyService(),
            modelDownloadService: WhisperModelDownloadService(modelsDirectoryURL: directory),
            whisperService: WhisperCPPService(),
            transcriptRefinementService: LlamaCLITranscriptRefinementService(),
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
    var restoreCalls = 0
    var isDucked = false
    var onRestore: (() -> Void)?
    var onBegin: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    func beginDucking() async throws {
        beginCalls += 1
        if shouldWait {
            await withCheckedContinuation { continuation = $0; onBegin?() }
        }
        isDucked = true
    }
    func resume() { continuation?.resume(); continuation = nil }
    func restoreDucking() async throws {
        restoreCalls += 1
        isDucked = false
        onRestore?()
    }
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
    var shouldWaitPreparation = false
    var onPrepare: (() -> Void)?
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    init(fileURL: URL) { self.fileURL = fileURL }
    func prepareRecording() async throws {
        if shouldWaitPreparation {
            await withCheckedContinuation { preparationContinuation = $0; onPrepare?() }
        }
    }
    func resumePreparation() { preparationContinuation?.resume(); preparationContinuation = nil }
    func shutdown() { isRecording = false }
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AudioRecorderServiceError.notRecording
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

@MainActor
private final class StartupPermissionService: PermissionServiceProtocol {
    var permission: MicrophonePermissionState
    init(permission: MicrophonePermissionState) { self.permission = permission }
    func currentMicrophonePermissionStatus() -> MicrophonePermissionState { permission }
    func requestMicrophonePermissionIfNeeded() async -> MicrophonePermissionState { permission }
    func isAccessibilityPermissionGranted() -> Bool { false }
    func requestAccessibilityPermission() -> Bool { XCTFail("No insertion is expected"); return false }
    func openMicrophoneSettings() {}
    func openAccessibilitySettings() {}
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
        return TextInsertionResult(text: text, method: .copyPanel, targetApplicationName: nil, completedAt: Date(), isInsertionConfirmed: false)
    }
    func copyTextToPasteboard(_ text: String) { XCTFail("No clipboard writes are expected") }
}

@MainActor
private final class StartupNotificationService: LocalNotificationServiceProtocol {
    func requestAuthorizationIfNeeded() {}
    func show(title: String, body: String) {}
}

@MainActor
private final class StartupCueService: SoundCueServiceProtocol {
    var played: [SoundCue] = []
    func play(_ cue: SoundCue, style: SoundCueStyle) async throws { played.append(cue) }
    func stop() {}
}
