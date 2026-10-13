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
    func testGemma4E2B() async throws { try await checkModel(.gemma4E2B) }
    func testPhi4Mini() async throws { try await checkModel(.phi4Mini) }

    func testQwen3FourBPreservesIndonesianIntent() async throws {
        let model = RefinementModelDescriptor.qwen3FourB2507
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(model.filename).path) else {
            throw XCTSkip("Pinned Qwen3 4B weights are not installed for intent-preservation checks")
        }
        let downloads = WhisperModelDownloadService(modelsDirectoryURL: fixtures)
        let verified = await downloads.verifiedRefinementModelURL(for: model)
        let modelURL = try XCTUnwrap(verified)
        let runtime = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "llama-server"))
        let service = LlamaCLITranscriptRefinementService(executableURL: runtime)
        let configuration = RefinementConfiguration(isEnabled: true, model: model, mode: .casualMessaging)
        let cases: [(source: String, required: [String], forbidden: [String], questions: Int)] = [
            (
                "Oke, ya berarti yang harus di exclude itu adalah kaca dan aluminium, cat interior. Kemudian pekerjaan kaca, kusen dan jendela itu kosong karena akan di provide oleh owner. Bongkaran bangunan lama memang kosong karena ini adalah tanah kosong. Sanitire ini akan di provide nanti. Jadi untuk scope dan exclusion pengerjaan harusnya cukup di struktur dan ME atau mechanical electric. Nah kira-kira apa saja pertanyaan yang bisa kita munculkan dari informasi ini?",
                ["kaca", "aluminium", "cat interior", "kusen", "jendela", "owner", "tanah kosong", "struktur", "ME", "pertanyaan"],
                ["siapa yang akan", "apakah sudah"], 1
            ),
            (
                "Oke kita fokus ke scope struktur. Apa yang bisa kita ulik dari RAB untuk membahas struktur? Tolong fokuskan ke hal-hal yang penting saja.",
                ["struktur", "RAB", "fokus", "penting"],
                ["alokasi sumber daya", "pengelolaan risiko", "berikut beberapa"], 1
            ),
            (
                "Siapa yang menyediakan kaca? Apakah cat interior termasuk scope?",
                ["siapa", "kaca", "apakah", "cat interior", "scope"], [], 2
            ),
            (
                "Owner akan menyediakan kaca. Cat interior tidak termasuk scope. Jadwalnya mungkin berubah.",
                ["owner", "kaca", "cat interior", "tidak", "scope", "mungkin"], [], 0
            )
        ]
        do {
            for sample in cases {
                for _ in 0..<3 {
                    let result = try await service.refine(transcript: sample.source, whisperTaskMode: .transcribe,
                        modelURL: modelURL, configuration: configuration,
                        promptTemplate: RefinementPromptTemplate.template(for: .casualMessaging))
                    for term in sample.required {
                        XCTAssertTrue(result.refinedText.localizedCaseInsensitiveContains(term), "Missing source detail: \(term)")
                    }
                    for term in sample.forbidden {
                        XCTAssertFalse(result.refinedText.localizedCaseInsensitiveContains(term), "Invented answer or question: \(term)")
                    }
                    XCTAssertEqual(result.refinedText.filter { $0 == "?" }.count, sample.questions)
                    XCTAssertFalse(result.refinedText.contains("<transcript>"))
                    XCTAssertFalse(result.refinedText.contains("</transcript>"))
                }
            }
        } catch { await service.stop(); throw error }
        await service.stop()
    }

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
        guard ProcessInfo.processInfo.environment["DICTAFLOW_RUN_QUALITY_PROBES"] == "1" else {
            throw XCTSkip("Known Qwen 0.6B quality limitation; set DICTAFLOW_RUN_QUALITY_PROBES=1 to run the strict probe")
        }
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
            XCTAssertTrue(result.refinedText.localizedCaseInsensitiveContains("Wednesday"))
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
