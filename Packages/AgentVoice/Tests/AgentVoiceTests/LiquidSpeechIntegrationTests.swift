@testable import AgentVoice
import Foundation
import Testing

/// Opt-in local synthesis with existing checksum-pinned assets. No downloads,
/// microphone, playback, history access, or changes to installed application settings.
struct LiquidSpeechIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTAFLOW_RUN_LIQUID_SPEECH_CHECKS"] == "1",
                   "Requires explicit opt-in and existing pinned Liquid fixtures."))
    func verifiedModelSynthesizesCompleteBoundedResponses() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = package.deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent(".build/agentvoice-fixtures")
        let assets = LiquidAssets(directory: fixtures.appendingPathComponent("models"))
        #expect(try await assets.isReady(), "Supply the existing pinned Liquid fixtures; this test never downloads them.")
        let output = root.appendingPathComponent(".build/liquid-speech-check")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let runtime = LiquidRuntime(executable: root.appendingPathComponent(".build/liquid-runtime/bin/llama-server"),
                                    assets: assets, configuration: LiquidRuntimeConfiguration(ttsSeed: 42))
        do {
            let longEnglish = Array(repeating: LiquidSpeechTests.historicalReview, count: 3).joined(separator: "\n\n")
            let french = "Bonjour, cette application conserve les données sur votre ordinateur. Vous pouvez arrêter la lecture à tout moment."
            let cases: [(String, String, Set<String>)] = [
                ("review-en", LiquidSpeechTests.historicalReview, ["en"]),
                ("short-en", "The result is ready. We still need to verify the application before release.", ["en"]),
                ("markdown-en", "# Verification\n\nThe **result** is ready. Read [the guide](https://example.com/guide).\n\nOpen `LiquidSpeechPlan.swift` and run `git diff --check`.\n\n```sh\ngit diff --check\n```\n\nSee https://example.com/a?source=preview for the details.", ["en"]),
                ("preview-en", longEnglish, ["en"]),
                ("speech-fr", french, ["fr"]),
                ("preview-fr", Array(repeating: french, count: 35).joined(separator: "\n\n"), ["en", "fr"]),
                ("preview-mixed", "The local voice test is complete.\n\nMerci beaucoup.\n\n" + longEnglish, ["en", "fr"]),
                ("cleanup-en", "# Verification\n\n- [x] Check complete.\n- [ ] Manual verification.\n\nHello <b>reader</b>.<br>Keep this result local.\n\n| Model | State |\n| Liquid | Ready |", ["en"])
            ]
            var reports: [[String: Any]] = []
            for (name, text, languages) in cases {
                let plan = try LiquidSpeechPlan.make(text)
                #expect(Set(plan.chunks.map(\.language)) == languages)
                #expect(plan.chunks.count <= LiquidSpeechPlan.maximumChunks)
                let speech = try await runtime.synthesize(text)
                await runtime.stop()
                #expect(await runtime.hasExited())
                #expect(speech.duration > 0 && speech.duration < 120)
                try speech.wav.write(to: output.appendingPathComponent(name + ".wav"))
                reports.append(["fixture": name, "language": languages.count == 1 ? languages.first! : "mixed",
                                "languages": languages.sorted(), "chunks": plan.chunks.count,
                                "preview": plan.chunks.first?.text == LiquidSpeechPlan.previewNotice,
                                "audio_seconds": speech.duration, "audio_bytes": speech.wav.count])
            }
            let synthesis = Task { try await runtime.synthesize(LiquidSpeechTests.historicalReview) }
            try await Task.sleep(for: .seconds(2))
            synthesis.cancel()
            await runtime.stop()
            await #expect(throws: (any Error).self) { try await synthesis.value }
            #expect(await runtime.hasExited())
            let report = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            try report.write(to: output.appendingPathComponent("report.json"))
        } catch {
            await runtime.stop()
            throw error
        }
    }
}
