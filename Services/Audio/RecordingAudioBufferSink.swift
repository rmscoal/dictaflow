import AVFoundation
import Foundation
import OSLog

// The tap copies into a bounded pool. Encoding and file I/O stay on the writer
// queue, and the lock only protects short state updates, never file writes.
final class RecordingAudioBufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.dictaflow.recording-writer")
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DictaFlow", category: "AudioCapture")
    private var file: AVAudioFile?
    private var availableBuffers: [AVAudioPCMBuffer]
    private var acceptingAudio = true
    private var firstError: Error?
    private var powerLevel: Double = 0
    private var writtenFrames: AVAudioFramePosition = 0
    private let format: AVAudioFormat
    private let bufferCapacity: AVAudioFrameCount

    init(file: AVAudioFile, format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else {
            throw AudioRecorderServiceError.failedToPrepare
        }
        self.file = file
        self.format = format
        // AVAudioEngine taps support buffers up to 400 ms. Reserve enough for
        // that at the selected device rate, rather than assuming 48 kHz input.
        let capacity = max(16_384, AVAudioFrameCount(ceil(format.sampleRate * 0.4)))
        bufferCapacity = capacity
        availableBuffers = try (0..<8).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw AudioRecorderServiceError.failedToPrepare
            }
            return buffer
        }
    }

    var currentPowerLevel: Double {
        lock.lock()
        defer { lock.unlock() }
        return powerLevel
    }

    var recordingError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return firstError
    }

    func fail(with error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if firstError == nil { firstError = error }
    }

    func append(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingAudio, firstError == nil, input.frameLength > 0 else { return }
        guard input.format == format, input.frameLength <= bufferCapacity,
              let buffer = availableBuffers.popLast() else {
            firstError = AudioRecorderServiceError.failedToWrite
            return
        }

        buffer.frameLength = input.frameLength
        guard let source = input.floatChannelData, let destination = buffer.floatChannelData else {
            firstError = AudioRecorderServiceError.failedToWrite
            availableBuffers.append(buffer)
            return
        }
        for channel in 0..<Int(format.channelCount) {
            destination[channel].update(from: source[channel], count: Int(input.frameLength))
        }

        // Enqueue while holding the state lock so finish() cannot overtake a
        // buffer that has been accepted but not yet handed to the writer.
        queue.async { [self, buffer] in
            var writeError: Error?
            do {
                guard let file else { throw AudioRecorderServiceError.failedToWrite }
                try file.write(from: buffer)
            } catch {
                let failure = error as NSError
                logger.error("Recording write failed: \(failure.domain, privacy: .public) (\(failure.code, privacy: .public))")
                writeError = AudioRecorderServiceError.failedToWrite
            }
            let level = Self.normalizedPower(of: buffer)
            lock.lock()
            if let writeError {
                if firstError == nil { firstError = writeError }
            } else {
                writtenFrames += AVAudioFramePosition(buffer.frameLength)
                powerLevel = level
            }
            availableBuffers.append(buffer)
            lock.unlock()
        }
    }

    func finish() throws -> TimeInterval {
        lock.lock()
        acceptingAudio = false
        lock.unlock()
        // Closing after queued writes finalizes the AAC container before decode.
        queue.sync { file = nil }
        lock.lock()
        defer { lock.unlock() }
        if let firstError { throw firstError }
        return Double(writtenFrames) / format.sampleRate
    }

    private static func normalizedPower(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var energy: Double = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                let sample = Double(channels[channel][frame])
                energy += sample * sample
            }
        }
        let meanEnergy = energy / Double(buffer.frameLength) / Double(buffer.format.channelCount)
        guard meanEnergy > 0, meanEnergy.isFinite else { return 0 }
        let decibels = 10 * log10(meanEnergy)
        return min(max((decibels + 55) / 55, 0), 1)
    }
}
