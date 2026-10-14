import AVFoundation
import CoreAudio
import XCTest
@testable import DictaFlow_Dev

/// Opt-in hardware checks. Captures stay in an isolated temporary directory and
/// are never transcribed, inserted, or added to the user's recording history.
@MainActor
final class RecordingAudioIntegrationTests: XCTestCase {
    func testCompareEngineAndRecorderStartup() async throws {
        try requireMicrophoneChecks()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DictaFlowAudioChecks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try outputSnapshot()
        var engineTimings: [Double] = []
        var recorderTimings: [Double] = []

        for index in 0..<3 {
            let engine = AVAudioEngine()
            defer { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
            let counter = CapturedFrameCounter()
            let began = ProcessInfo.processInfo.systemUptime
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                counter.append(buffer.frameLength)
            }
            engine.prepare()
            try engine.start()
            engineTimings.append((ProcessInfo.processInfo.systemUptime - began) * 1_000)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(try outputSnapshot(), output, "Capture changed the output device, rate, or master volume")
            engine.stop()
            XCTAssertGreaterThan(counter.frameCount, 0, "An engine reporting ready must deliver actual microphone frames")
            XCTAssertEqual(try outputSnapshot(), output)
            try await assertMicrophoneReleased()

            let service = SystemAudioRecorderService()
            defer { service.shutdown() }
            let recorderURL = directory.appendingPathComponent("recorder-\(index).m4a")
            let recorderBegan = ProcessInfo.processInfo.systemUptime
            try await service.prepareRecording(at: recorderURL)
            _ = try await service.startRecording()
            recorderTimings.append((ProcessInfo.processInfo.systemUptime - recorderBegan) * 1_000)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(try outputSnapshot(), output)
            let capture = try await service.stopRecording()
            XCTAssertGreaterThan(capture.duration, 0.1)
            let recorderAudio = try await AVAudioDecodingService().decodePCMFloatSamples(from: recorderURL)
            XCTAssertGreaterThan(recorderAudio.count, 1_600)
            XCTAssertTrue(recorderAudio.allSatisfy(\.isFinite))
            let attributes = try FileManager.default.attributesOfItem(atPath: recorderURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try outputSnapshot(), output)
            try await assertMicrophoneReleased()
        }
        print("Audio startup comparison (ms): input-only AVAudioEngine \(engineTimings); AVAudioRecorder \(recorderTimings)")
    }

    func testPreparationFailureAndCancellationReleaseInput() async throws {
        try requireMicrophoneChecks()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DictaFlowAudioCleanup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = SystemAudioRecorderService()
        defer { service.shutdown() }
        let output = try outputSnapshot()

        do {
            try await service.prepareRecording(at: directory.appendingPathComponent("missing-parent/capture.m4a"))
            XCTFail("Preparation should fail when the destination parent is missing")
        } catch {}
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(try outputSnapshot(), output)
        try await assertMicrophoneReleased()

        let url = directory.appendingPathComponent("cancelled.m4a")
        try await service.prepareRecording(at: url)
        try await service.discardRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(service.isRecording)
        try await assertMicrophoneReleased()

        try await service.prepareRecording(at: url)
        _ = try await service.startRecording()
        do {
            _ = try await service.startRecording()
            XCTFail("A duplicate start should be rejected without cancelling the active capture")
        } catch let error as AudioRecorderServiceError {
            XCTAssertEqual(error, .alreadyRecording)
        }
        XCTAssertTrue(service.isRecording)
        try await Task.sleep(for: .milliseconds(200))
        try await service.discardRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(try outputSnapshot(), output)
        try await assertMicrophoneReleased()
    }

    private func requireMicrophoneChecks() throws {
        guard ProcessInfo.processInfo.environment["DICTAFLOW_RUN_AUDIO_CHECKS"] == "1" else {
            throw XCTSkip("Set DICTAFLOW_RUN_AUDIO_CHECKS=1 to compare real microphone capture APIs")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Microphone checks require existing permission; they never request it")
        }
    }

    private struct OutputSnapshot: Equatable {
        let device: AudioDeviceID
        let sampleRate: Float64
        let volume: Float32?
    }

    private func assertMicrophoneReleased() async throws {
        guard #available(macOS 14.2, *) else { return }
        for _ in 0..<20 {
            if try !processInputIsRunning() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Core Audio still reports active microphone input after cleanup")
    }

    @available(macOS 14.2, *)
    private func processInputIsRunning() throws -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        let sizeStatus = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard sizeStatus == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(sizeStatus)) }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let listStatus = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard listStatus == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(listStatus)) }
        for object in objects {
            address.mSelector = kAudioProcessPropertyPID
            var pid: pid_t = 0
            size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr,
                  pid == ProcessInfo.processInfo.processIdentifier else { continue }
            address.mSelector = kAudioProcessPropertyIsRunningInput
            var running: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running)
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            if running != 0 { return true }
        }
        return false
    }

    private func outputSnapshot() throws -> OutputSnapshot {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let deviceStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard deviceStatus == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(deviceStatus)) }
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        var rate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        let rateStatus = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        guard rateStatus == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(rateStatus)) }
        address.mSelector = kAudioDevicePropertyVolumeScalar
        address.mScope = kAudioObjectPropertyScopeOutput
        var volume: Float32 = 0
        size = UInt32(MemoryLayout<Float32>.size)
        let volumeStatus = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return OutputSnapshot(device: device, sampleRate: rate, volume: volumeStatus == noErr ? volume : nil)
    }
}

private final class CapturedFrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: UInt64 = 0
    var frameCount: UInt64 { lock.withLock { frames } }
    func append(_ count: AVAudioFrameCount) { lock.withLock { frames += UInt64(count) } }
}
