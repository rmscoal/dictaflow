import AgentVoice
import Foundation
import Testing

struct LiquidAudioChunkerTests {
    private let sampleRate = 16_000.0

    @Test func emptySamplesProduceNoChunks() {
        #expect(LiquidAudioChunker.split(samples: [], sampleRate: sampleRate).isEmpty)
    }

    @Test func shortRecordingStaysSingleChunk() {
        let samples = tone(seconds: 60)
        let chunks = LiquidAudioChunker.split(samples: samples, sampleRate: sampleRate)
        #expect(chunks.count == 1)
        #expect(chunks.first == 0..<samples.count)
    }

    @Test func recordingAtMaxStaysSingleChunk() {
        let samples = tone(seconds: Int(LiquidAudioChunker.maxChunkDuration))
        let chunks = LiquidAudioChunker.split(samples: samples, sampleRate: sampleRate)
        #expect(chunks.count == 1)
    }

    @Test func continuousAudioCutsAtMaxWithNoOverlap() {
        let samples = tone(seconds: 300)
        let chunks = LiquidAudioChunker.split(samples: samples, sampleRate: sampleRate)
        #expect(chunks.count == 3)
        assertExactPartition(chunks, total: samples.count)
        for chunk in chunks {
            #expect(Double(chunk.count) / sampleRate <= LiquidAudioChunker.maxChunkDuration)
        }
    }

    @Test func cutPrefersSilenceNearTarget() {
        // Speech, then a 10 s pause at 95-105 s, then speech to 200 s.
        var samples = tone(seconds: 95)
        samples += [Float](repeating: 0, count: seconds(10))
        samples += tone(seconds: 95)
        #expect(samples.count == seconds(200))
        let chunks = LiquidAudioChunker.split(samples: samples, sampleRate: sampleRate)
        #expect(chunks.count == 2)
        assertExactPartition(chunks, total: samples.count)
        let cut = Double(chunks[0].upperBound) / sampleRate
        #expect(cut >= 95 && cut <= 105, "Cut at \(cut) s must land inside the pause.")
    }

    @Test func tinyTailMergesIntoPreviousChunk() {
        // 121 s of continuous tone: naive cut at 110 s leaves an 11 s tail,
        // which merges back so the tail is exactly the 15 s minimum.
        let samples = tone(seconds: 121)
        let chunks = LiquidAudioChunker.split(samples: samples, sampleRate: sampleRate)
        #expect(chunks.count == 2)
        assertExactPartition(chunks, total: samples.count)
        #expect(chunks[1].count == seconds(15))
        #expect(Double(chunks[0].count) / sampleRate <= LiquidAudioChunker.maxChunkDuration)
    }

    private func seconds(_ value: Int) -> Int { Int(Double(value) * sampleRate) }

    private func tone(seconds value: Int) -> [Float] {
        let count = seconds(value)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = 0.5 * sin(2 * Float.pi * 440 * Float(i) / Float(sampleRate))
        }
        return samples
    }

    private func assertExactPartition(_ chunks: [Range<Int>], total: Int) {
        #expect(chunks.first?.lowerBound == 0)
        #expect(chunks.last?.upperBound == total)
        for pair in zip(chunks, chunks.dropFirst()) {
            #expect(pair.0.upperBound == pair.1.lowerBound, "Chunks must join with no gap or overlap.")
        }
    }
}
