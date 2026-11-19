import AgentVoice
import Foundation
import Testing

struct LiquidBenchmarkTests {
    @Test func productionDefaultCarriesEfficiencyFlags() async throws {
        let defaults = LiquidRuntimeConfiguration.productionDefault
        #expect(defaults.ttsSeed == nil)
        #expect(defaults.extraServerArguments.isEmpty)
        #expect(defaults.serverEnvironment == nil)
        #expect(defaults.healthPollInterval == .milliseconds(20))

        let assets = LiquidAssets(directory: URL(fileURLWithPath: "/tmp/dictaflow-benchmark-fixture"))
        let runtime = LiquidRuntime(executable: URL(fileURLWithPath: "/tmp/llama-server"),
                                    assets: assets, configuration: .productionDefault)
        let port: UInt16 = 18231
        let arguments = await runtime.serverArguments(apiKey: "probe", port: port)
        let models = assets.directory.path
        #expect(arguments == ["--model", "\(models)/LFM3-Audio-2B-Q4_K_M.gguf",
                              "--mmproj", "\(models)/mmproj-LFM3-Audio-2B-Q8_0.gguf",
                              "--host", "127.0.0.1", "--port", "18231",
                              "--alias", "dictaflow-liquid",
                              "--ctx-size", "4096", "--parallel", "1",
                              "--no-webui", "--api-key", "probe",
                              "--poll", "0", "--poll-batch", "0"])
    }

    @Test func ttsPayloadGainsSeedOnlyWhenConfigured() {
        let legacy = LiquidRuntime.ttsPayload(text: "fixture", seed: nil)
        #expect(Set(legacy.keys) == ["input", "lang", "voice", "stream",
                                     "response_format", "n_predict", "repeat_penalty"])
        #expect(legacy["voice"] as? String == "female")
        let seeded = LiquidRuntime.ttsPayload(text: "fixture", seed: 20261102)
        #expect(seeded["seed"] as? UInt32 == 20261102)
        #expect(Set(seeded.keys) == Set(legacy.keys).union(["seed"]))
    }

    @Test func ttsPresetDoesNotChangeLanguageOrSampling() {
        let male = LiquidRuntime.ttsPayload(text: "Bonjour.", seed: nil, language: "fr", voice: .male, englishAccent: .british)
        #expect(male["voice"] as? String == "male")
        #expect(male["lang"] as? String == "fr")
        #expect(male["repeat_penalty"] as? Double == 1.1)
        #expect(male["seed"] == nil)
    }

    @Test func ttsPayloadSelectsEnglishAccent() {
        let american = LiquidRuntime.ttsPayload(text: "Hello.", seed: nil)
        let british = LiquidRuntime.ttsPayload(text: "Hello.", seed: nil, englishAccent: .british)
        #expect(american["lang"] as? String == "en")
        #expect(british["lang"] as? String == "en-gb")
        #expect(british["voice"] as? String == american["voice"] as? String)
    }

    @Test func medianCoversOddEvenAndEmpty() {
        #expect(LiquidBenchmarkStatistics.median([]) == nil)
        #expect(LiquidBenchmarkStatistics.median([1.5]) == 1.5)
        #expect(LiquidBenchmarkStatistics.median([3.0, 1.0, 2.0]) == 2.0)
        #expect(LiquidBenchmarkStatistics.median([4.0, 1.0, 3.0, 2.0]) == 2.5)
    }
}
