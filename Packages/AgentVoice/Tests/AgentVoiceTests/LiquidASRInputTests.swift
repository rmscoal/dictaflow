import AgentVoice
import AVFoundation
import Foundation
import Testing

struct LiquidASRInputTests {
    @Test func byteOverlimitFailsBeforeServer() throws {
        let data = Data(count: LiquidRuntime.maxASRBytes + 1)
        do {
            try LiquidRuntime.validateASRInput(data)
            Issue.record("8 MiB input must fail.")
        } catch let error as VoiceError {
            guard case .inputTooLong(let message) = error else {
                Issue.record("Expected inputTooLong, got \(error).")
                return
            }
            #expect(message.contains("8 MiB"))
            #expect(message.contains("recording is kept"))
        }
    }

    @Test func durationOverlimitFailsWithBoundedFixture() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilence(to: url, seconds: 121, sampleRate: 16_000)
        let data = try Data(contentsOf: url)
        #expect(data.count < LiquidRuntime.maxASRBytes)
        do {
            try LiquidRuntime.validateASRInput(data)
            Issue.record("121 s input must fail.")
        } catch let error as VoiceError {
            guard case .inputTooLong(let message) = error else {
                Issue.record("Expected inputTooLong, got \(error).")
                return
            }
            #expect(message.contains("2 minutes"))
            #expect(message.contains("recording is kept"))
        }
    }

    @Test func validFixturePassesWithoutServer() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = package.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/agentvoice-fixtures/speech.wav")
        guard FileManager.default.fileExists(atPath: fixture.path) else { return }
        let data = try Data(contentsOf: fixture)
        try LiquidRuntime.validateASRInput(data)
    }

    @Test func invalidAudioFailsWithoutServer() throws {
        do {
            try LiquidRuntime.validateASRInput(Data("not-audio".utf8))
            Issue.record("Invalid audio must fail.")
        } catch let error as VoiceError {
            if case .inputTooLong = error { Issue.record("Invalid audio must not report overlimit.") }
        }
        do {
            try LiquidRuntime.validateASRInput(Data())
            Issue.record("Empty audio must fail.")
        } catch {}
    }

    private func writeSilence(to url: URL, seconds: Int, sampleRate: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw VoiceError.unavailable("Test fixture failed.")
            }
            buffer.frameLength = frames
            if let channel = buffer.floatChannelData?[0] {
                for i in 0..<Int(frames) { channel[i] = 0 }
            }
            for _ in 0..<seconds { try file.write(from: buffer) }
        }
    }
}
