import Foundation

/// Splits decoded 16 kHz mono samples into transcription chunks that each fit
/// a single Liquid ASR request.
///
/// A single request is bounded by the pinned sidecar context
/// (`--ctx-size 4096` with `max_tokens` 2048, about 12.5 prompt tokens per
/// audio second). Chunks target 90 seconds and never exceed 110 seconds, so
/// every chunk stays inside the per-request guards in
/// `LiquidRuntime.validateASRInput` (120 s, 8 MiB: 110 s of 16 kHz mono
/// float32 is about 7 MB) with margin.
///
/// Cut points prefer real pauses: each frame is marked silent by RMS energy
/// against a relative threshold, and the longest silence run inside the
/// search window wins, cut at its midpoint. Every sample lands in exactly
/// one chunk. There is deliberately no overlap and no text deduplication:
/// translation can render the same phrase differently across windows, so
/// overlapping words cannot be assigned to one chunk reliably.
public enum LiquidAudioChunker {
    /// Preferred chunk length. Cuts search for a pause near and above this.
    public static let targetChunkDuration: TimeInterval = 90
    /// Hard chunk length. Never exceeded, keeping per-request guards happy.
    public static let maxChunkDuration: TimeInterval = 110
    /// Tails shorter than this are folded into the previous chunk when the
    /// merged chunk still fits `maxChunkDuration`.
    static let minTailDuration: TimeInterval = 15
    /// A chunk is never shortened below this to fatten a tail.
    static let minChunkDuration: TimeInterval = 30
    /// Energy frame length for silence detection.
    static let frameDuration: TimeInterval = 0.02
    /// A pause must last at least this long to win a cut.
    static let minPauseDuration: TimeInterval = 0.3

    /// Returns sample ranges covering `0..<samples.count` with no gaps and
    /// no overlaps. Empty input returns no chunks.
    public static func split(samples: [Float], sampleRate: Double) -> [Range<Int>] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let maxChunk = Int(maxChunkDuration * sampleRate)
        guard samples.count > maxChunk else { return [0..<samples.count] }

        let framesPerSecond = 1 / frameDuration
        let frameSamples = max(1, Int(frameDuration * sampleRate))
        let frameCount = (samples.count + frameSamples - 1) / frameSamples
        var energy = [Float](repeating: 0, count: frameCount)
        var total: Double = 0
        for frame in 0..<frameCount {
            let start = frame * frameSamples
            let end = min(start + frameSamples, samples.count)
            var sum: Double = 0
            for i in start..<end { sum += Double(samples[i]) * Double(samples[i]) }
            let rms = Float(sqrt(sum / Double(max(1, end - start))))
            energy[frame] = rms
            total += Double(rms * rms)
        }
        let overall = Float(sqrt(total / Double(max(1, frameCount))))
        let threshold = max(0.01, 0.1 * overall)

        let targetChunk = Int(targetChunkDuration * sampleRate)
        let minTail = Int(minTailDuration * sampleRate)
        let minChunk = Int(minChunkDuration * sampleRate)
        let minPauseFrames = max(1, Int(minPauseDuration * framesPerSecond))

        var chunks: [Range<Int>] = []
        var position = 0
        while samples.count - position > maxChunk {
            let windowStart = position + targetChunk
            let windowEnd = min(position + maxChunk, samples.count)
            var cut = windowEnd
            let startFrame = windowStart / frameSamples
            let endFrame = min(frameCount - 1, windowEnd / frameSamples)
            if startFrame <= endFrame {
                var bestStart = -1
                var bestLength = 0
                var runStart = -1
                var frame = startFrame
                while frame <= endFrame + 1 {
                    let silent = frame <= endFrame && energy[frame] < threshold
                    if silent, runStart < 0 { runStart = frame }
                    if !silent, runStart >= 0 {
                        let length = frame - runStart
                        if length >= minPauseFrames, length > bestLength {
                            bestLength = length
                            bestStart = runStart
                        }
                        runStart = -1
                    }
                    frame += 1
                }
                if bestStart >= 0 {
                    let runEnd = min(bestStart + bestLength, endFrame + 1)
                    let midpoint = (bestStart + runEnd) / 2
                    cut = min(max(midpoint * frameSamples, windowStart), windowEnd)
                }
            }
            let remainder = samples.count - cut
            if remainder < minTail, cut - minTail >= position + minChunk {
                cut -= minTail - remainder
            }
            chunks.append(position..<cut)
            position = cut
        }
        chunks.append(position..<samples.count)
        return chunks
    }
}
