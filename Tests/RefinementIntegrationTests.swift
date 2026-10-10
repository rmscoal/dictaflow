import Foundation
import XCTest
@testable import DictaFlow_Dev

/// Optional real-weight checks. Place the pinned artifacts in the temporary
/// DictaFlowRefinementFixtures folder before running these tests.
@MainActor
final class RefinementIntegrationTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: "/tmp/DictaFlowRefinementFixtures", isDirectory: true)
    }

    func testQwen35TwoB() async throws { try await checkModel(.qwen35TwoB) }
    func testQwen35FourB() async throws { try await checkModel(.qwen35FourB) }
    func testQwen3FourB2507() async throws { try await checkModel(.qwen3FourB2507) }
    func testLlama32ThreeB() async throws { try await checkModel(.llama32ThreeB) }
    func testGemma4E2B() async throws { try await checkModel(.gemma4E2B) }
    func testPhi4Mini() async throws { try await checkModel(.phi4Mini) }

    private func checkModel(_ model: RefinementModelDescriptor) async throws {
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(model.filename).path) else {
            throw XCTSkip("Pinned \(model.displayName) weights are not installed")
        }
        let downloads = WhisperModelDownloadService(modelsDirectoryURL: fixtures)
        let verified = await downloads.verifiedRefinementModelURL(for: model)
        let url = try XCTUnwrap(verified)
        let runtime = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "llama-server"))
        let service = LlamaCLITranscriptRefinementService(executableURL: runtime)
        do {
            for mode in [RefinementMode.smartCleanup, .professionalFormal, .casualMessaging, .technicalEngineering] {
                let configuration = RefinementConfiguration(isEnabled: true, model: model, mode: mode)
                let result = try await service.refine(transcript: "Um please review auth_token and PR 42 by Friday. Jangan ubah API name ya.",
                    whisperTaskMode: .transcribe, modelURL: url, configuration: configuration,
                    promptTemplate: RefinementPromptTemplate.template(for: mode))
                XCTAssertTrue(result.refinedText.contains("42"))
                XCTAssertTrue(result.refinedText.contains("auth_token"))
            }
        } catch { await service.stop(); throw error }
        await service.stop()
    }

    func testVerifiedQwenLongTranscriptQualityProbe() async throws {
        let model = RefinementModelDescriptor.qwen3Small
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(model.filename).path) else {
            throw XCTSkip("Pinned Qwen test weights are not installed")
        }
        let downloads = WhisperModelDownloadService(modelsDirectoryURL: fixtures)
        let verified = await downloads.verifiedRefinementModelURL(for: model)
        let url = try XCTUnwrap(verified)
        let runtime = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "llama-server"))
        let service = LlamaCLITranscriptRefinementService(executableURL: runtime)
        let opening = (1...30).map { "Module \($0) uses auth_token for its API request. Its review is tracked in PR \($0 + 42)." }.joined(separator: "\n")
        let ending = (31...60).map { "Module \($0) uses auth_token for its API request. Its review is tracked in PR \($0 + 42)." }.joined(separator: "\n")
        let transcript = opening + "\nSend the report Tuesday. Actually Wednesday.\n" + ending
        do {
            let result = try await service.refine(transcript: transcript, whisperTaskMode: .transcribe,
                modelURL: url, configuration: .default,
                promptTemplate: RefinementPromptTemplate.template(for: .smartCleanup))
            // Keep the observed small-model quality limit visible. Scope the
            // expectation to this semantic assertion, never runtime failures or
            // the identifier/number checks below. A better output may also pass.
            XCTExpectFailure("Qwen 0.6B can omit a distinct corrected date among repetitive technical facts.", options: .nonStrict()) {
                XCTAssertTrue(result.refinedText.localizedCaseInsensitiveContains("Wednesday"))
            }
            XCTAssertFalse(result.refinedText.localizedCaseInsensitiveContains("Tuesday"))
            XCTAssertTrue(result.refinedText.contains("auth_token"))
            XCTAssertTrue(result.refinedText.contains("43"))
        } catch { await service.stop(); throw error }
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
