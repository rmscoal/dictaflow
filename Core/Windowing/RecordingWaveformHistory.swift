import Foundation

// Each sample keeps its height while the renderer moves it across the pill.
struct RecordingWaveformHistory {
    static let visibleBarCount = 18
    static let sampleInterval: TimeInterval = 0.1

    // One extra bar enters from beyond the right edge as the oldest exits left.
    private(set) var levels = Array(repeating: 0.0, count: visibleBarCount + 1)
    private(set) var lastSampleTime: TimeInterval?

    mutating func append(level: Double, at time: TimeInterval) -> Bool {
        let normalizedLevel = level.isFinite ? min(max(level, 0), 1) : 0
        guard let lastSampleTime else {
            levels.removeFirst()
            levels.append(normalizedLevel)
            self.lastSampleTime = time
            return true
        }

        let elapsedIntervals = floor((time - lastSampleTime) / Self.sampleInterval)
        guard elapsedIntervals >= 1 else { return false }

        // Leave gaps empty rather than inventing past levels after a UI stall.
        let sampleCount = Int(min(elapsedIntervals, Double(levels.count)))
        levels.removeFirst(sampleCount)
        levels.append(contentsOf: repeatElement(0, count: sampleCount - 1))
        levels.append(normalizedLevel)
        self.lastSampleTime = lastSampleTime + elapsedIntervals * Self.sampleInterval
        return true
    }

    func scrollProgress(at time: TimeInterval) -> Double {
        guard let lastSampleTime else { return 0 }
        // Keep moving between meter ticks, even if the next sample arrives late.
        return min(max((time - lastSampleTime) / Self.sampleInterval, 0), Double(levels.count))
    }
}
