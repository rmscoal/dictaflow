import Foundation
import MLX
import XCTest
@testable import DictaFlow_Dev

/// Optional real-weight checks. Place the pinned artifacts in the temporary
/// DictaFlowRefinementFixtures folder before running these tests.
@MainActor
final class RefinementIntegrationTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: "/tmp/DictaFlowRefinementFixtures", isDirectory: true)
    }

    func testVerifiedMLXInferenceReleasesWeightsAfterIdle() async throws {
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(RefinementModelDescriptor.qwen3SmallMLX.filename).path) else {
            throw XCTSkip("Pinned MLX test weights are not installed")
        }
        let downloads = WhisperModelDownloadService(modelsDirectoryURL: fixtures)
        let verified = await downloads.verifiedRefinementModelURL(for: .qwen3SmallMLX)
        let modelURL = try XCTUnwrap(verified, "Every MLX file must pass its pinned checksum")
        let service = MLXTranscriptRefinementService(idleSleepSeconds: 2)
        let baselineMemory = Memory.activeMemory
        let started = ContinuousClock.now
        do {
            try await service.prepare(modelURL: modelURL)
            print("MLX cold preparation: \(started.duration(to: .now))")
            XCTAssertGreaterThan(Memory.activeMemory - baselineMemory, 200_000_000)
            let configuration = RefinementConfiguration(isEnabled: true, model: .qwen3SmallMLX, mode: .smartCleanup)
            for transcript in ["Um please send the report on Friday, Friday please.", "Tolong kirim laporannya besok pagi ya."] {
                let inferenceStart = ContinuousClock.now
                let result = try await service.refine(transcript: transcript, whisperTaskMode: .transcribe,
                    modelURL: modelURL, configuration: configuration, promptTemplate: "")
                XCTAssertFalse(result.refinedText.isEmpty)
                XCTAssertFalse(result.refinedText.contains("<think>"))
                print("MLX warm refinement: \(inferenceStart.duration(to: .now))")
            }
            try await Task.sleep(for: .seconds(3))
            XCTAssertLessThan(Memory.activeMemory - baselineMemory, 10_000_000)
            XCTAssertLessThan(Memory.cacheMemory, 10_000_000)
        } catch {
            await service.stop()
            throw error
        }
        await service.stop()
    }

    func testVerifiedLlamaInferenceAndWakeAfterIdle() async throws {
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(RefinementModelDescriptor.qwen3Small.filename).path) else {
            throw XCTSkip("Pinned GGUF test weights are not installed")
        }
        let downloads = WhisperModelDownloadService(modelsDirectoryURL: fixtures)
        let verified = await downloads.verifiedRefinementModelURL(for: .qwen3Small)
        let modelURL = try XCTUnwrap(verified)
        let runtime = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "llama-server"))
        let service = LlamaCLITranscriptRefinementService(executableURL: runtime, idleSleepSeconds: 2)
        let started = ContinuousClock.now
        do {
            try await service.prepare(modelURL: modelURL)
            print("llama cold preparation: \(started.duration(to: .now))")
            for transcript in ["Um please send the report on Friday, Friday please.", "Tolong kirim laporannya besok pagi ya."] {
                let inferenceStart = ContinuousClock.now
                let result = try await service.refine(transcript: transcript, whisperTaskMode: .transcribe,
                    modelURL: modelURL, configuration: .default, promptTemplate: "")
                XCTAssertFalse(result.refinedText.isEmpty)
                print("llama warm refinement: \(inferenceStart.duration(to: .now))")
            }
            try await Task.sleep(for: .seconds(4))
            let wakeStarted = ContinuousClock.now
            try await service.prepare(modelURL: modelURL)
            print("llama preparation after idle: \(wakeStarted.duration(to: .now))")
            let result = try await service.refine(transcript: "Please send the report tomorrow.", whisperTaskMode: .transcribe,
                modelURL: modelURL, configuration: .default, promptTemplate: "")
            XCTAssertFalse(result.refinedText.isEmpty)
        } catch {
            await service.stop()
            throw error
        }
        await service.stop()
    }
}
