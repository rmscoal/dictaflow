// Synthetic PCM only. These checks never create an audio engine or open a microphone.
import AVFoundation
import Foundation

@main
private struct NativeCaptureChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictaflow-native-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let url = directory.appendingPathComponent("capture-\(Int(rate)).m4a")
            let sink = try makeSink(at: url, format: format)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
            buffer.frameLength = 4_096
            let samples = buffer.floatChannelData![0]
            let chunks = 6
            for chunk in 0..<chunks {
                for frame in 0..<Int(buffer.frameLength) {
                    let time = Double(chunk * 4_096 + frame) / rate
                    samples[frame] = Float(0.2 * sin(2 * .pi * 740 * time))
                }
                sink.append(buffer)
                // Reusing this buffer verifies the sink copied it before return.
                samples.update(repeating: 0, count: Int(buffer.frameLength))
            }
            let expectedDuration = Double(chunks * 4_096) / rate
            let duration = try sink.finish()
            precondition(abs(duration - expectedDuration) < 0.000001, "Opening or trailing frames were lost")
            precondition(sink.currentPowerLevel > 0.5, "Meter did not use captured PCM")
            precondition(sink.recordingError == nil)
            sink.append(buffer)
            let finishedDuration = try sink.finish()
            precondition(finishedDuration == duration, "Audio was accepted after capture ended")

            let decoder = AVAudioDecodingService()
            let decoded = try await decoder.decodePCMFloatSamples(from: url)
            precondition(abs(Double(decoded.count) / 16_000 - duration) < 0.07,
                         "AAC finalization or Whisper conversion lost audio")
            let edgeFrames = min(512, decoded.count)
            precondition(rms(Array(decoded.prefix(edgeFrames))) > 0.04, "Immediate opening audio was removed")
            precondition(rms(Array(decoded.suffix(edgeFrames))) > 0.04, "Final audio was removed")
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let changed = try makeSink(at: directory.appendingPathComponent("changed.m4a"), format: format)
        changed.fail(with: AudioRecorderServiceError.audioDeviceChanged)
        do {
            _ = try changed.finish()
            fatalError("Device change was accepted as a successful capture")
        } catch AudioRecorderServiceError.audioDeviceChanged {}

        let invalid = try makeSink(at: directory.appendingPathComponent("invalid.m4a"), format: format)
        let oversized = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768)!
        oversized.frameLength = 32_768
        invalid.append(oversized)
        do {
            _ = try invalid.finish()
            fatalError("Buffer overflow silently discarded audio")
        } catch AudioRecorderServiceError.failedToWrite {}

        print("Passed: bounded PCM copying, opening/trailing audio preservation, metering, AAC finalization, Whisper decoding at three input rates, and interruption/overflow errors. No audio hardware used.")
    }

    private static func makeSink(at url: URL, format: AVAudioFormat) throws -> RecordingAudioBufferSink {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        return try RecordingAudioBufferSink(file: file, format: format)
    }

    private static func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }
}
