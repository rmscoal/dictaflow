import AgentVoice
import CryptoKit
import Foundation

let benchmarkFlag = "--tts-benchmark"
let benchmarkOnly = CommandLine.arguments.contains(benchmarkFlag)
guard CommandLine.arguments.count >= 3, !benchmarkOnly || CommandLine.arguments.count >= 4 else {
    FileHandle.standardError.write(Data("Usage: dictaflow-audio-check RUNTIME_DIRECTORY FIXTURE_DIRECTORY [--tts-benchmark [--runs N] [--seed S] [--compare VARIANT] [--text SENTENCE]]\nDefault: downloads pinned assets if missing and checks TTS/ASR/cancellation. Benchmark: requires existing verified assets and measures fresh-process TTS runs. Neither mode plays audio.\n".utf8))
    exit(2)
}
let runtimeDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
let assets = LiquidAssets(directory: fixtureDirectory.appendingPathComponent("models"))

func flagValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.endIndex else { return nil }
    return args[index + 1]
}

func productionPollMs() -> Int {
    let components = LiquidRuntimeConfiguration.productionDefault.healthPollInterval.components
    return max(1, Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15))
}

func healthPollMs(_ interval: Duration?) -> Int {
    guard let interval else { return productionPollMs() }
    let components = interval.components
    return max(1, Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15))
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func serverVersion(_ executable: URL) -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return "unavailable"
    }
}

/// Minimal inherited environment so benchmark candidates run isolated from
/// ambient developer shell settings. Keys are reported; values never are.
func benchmarkEnvironment() -> [String: String] {
    let parent = ProcessInfo.processInfo.environment
    var isolated: [String: String] = [:]
    for key in ["PATH", "TMPDIR", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "USER", "LOGNAME"] {
        if let value = parent[key] { isolated[key] = value }
    }
    return isolated
}

struct BenchmarkVariant: Sendable {
    let name: String
    let extraServerArguments: [String]
    /// Nil means the production default (20 ms since the efficiency pass).
    /// Benchmark-only; production never inherits this value.
    let healthPollInterval: Duration?
    init(name: String, extraServerArguments: [String] = [], healthPollInterval: Duration? = nil) {
        self.name = name; self.extraServerArguments = extraServerArguments
        self.healthPollInterval = healthPollInterval
    }
}

/// Historical one-variable experiments plus no-op controls. Since the
/// efficiency pass, baseline already carries `--poll 0 --poll-batch 0` and
/// 20 ms readiness polling, so `poll0`, `healthpoll20`, and `poll0_ready20`
/// now serve as no-op controls (or the old 100 ms readiness check) rather
/// than new candidates.
let knownVariants: [String: BenchmarkVariant] = [
    "threads10": BenchmarkVariant(name: "threads10", extraServerArguments: ["-t", "10", "-tb", "10"]),
    "poll100": BenchmarkVariant(name: "poll100", extraServerArguments: ["--poll", "100", "--poll-batch", "1"]),
    "healthpoll100": BenchmarkVariant(name: "healthpoll100", healthPollInterval: .milliseconds(100)),
    "threads4": BenchmarkVariant(name: "threads4", extraServerArguments: ["-t", "4", "-tb", "4"]),
    "threads6": BenchmarkVariant(name: "threads6", extraServerArguments: ["-t", "6", "-tb", "6"]),
    "threads8": BenchmarkVariant(name: "threads8", extraServerArguments: ["-t", "8", "-tb", "8"]),
    "ubatch256": BenchmarkVariant(name: "ubatch256", extraServerArguments: ["-ub", "256"]),
    "batch512": BenchmarkVariant(name: "batch512", extraServerArguments: ["-b", "512"]),
    "ctx2048": BenchmarkVariant(name: "ctx2048", extraServerArguments: ["--ctx-size", "2048"]),
    "nowarmup": BenchmarkVariant(name: "nowarmup", extraServerArguments: ["--no-warmup"]),
    "poll0": BenchmarkVariant(name: "poll0", extraServerArguments: ["--poll", "0", "--poll-batch", "0"]),
    "healthpoll20": BenchmarkVariant(name: "healthpoll20", healthPollInterval: .milliseconds(20)),
    "healthpoll50": BenchmarkVariant(name: "healthpoll50", healthPollInterval: .milliseconds(50)),
    // Two-variable kept-set verification only (not one-variable attribution):
    // poll0 server flags plus 20 ms readiness polling.
    "poll0_ready20": BenchmarkVariant(name: "poll0_ready20",
                                      extraServerArguments: ["--poll", "0", "--poll-batch", "0"],
                                      healthPollInterval: .milliseconds(20)),
]

func runOnce(runtimeDirectory: URL, assets: LiquidAssets, text: String, seed: UInt32,
             extraArguments: [String], environment: [String: String],
             healthPollInterval: Duration? = nil) async throws -> [String: Any] {
    let configuration = LiquidRuntimeConfiguration(ttsSeed: seed, extraServerArguments: extraArguments,
                                                   serverEnvironment: environment,
                                                   healthPollInterval: healthPollInterval ?? LiquidRuntimeConfiguration.productionDefault.healthPollInterval)
    let runtime = LiquidRuntime(executable: runtimeDirectory.appendingPathComponent("llama-server"),
                                assets: assets, configuration: configuration)
    do {
        let started = ContinuousClock.now
        let speech = try await runtime.synthesize(text)
        guard let timings = await runtime.lastSynthesisTimings else { throw VoiceError.unavailable("Synthesis timings are missing.") }
        await runtime.stop()
        guard await runtime.hasExited() else { throw VoiceError.unavailable("Benchmark could not observe runtime exit.") }
        let elapsed = started.duration(to: .now).components
        return ["startup_seconds": timings.startupSeconds,
                "request_seconds": timings.requestSeconds,
                "validation_seconds": timings.validationSeconds,
                "response_header_seconds": timings.responseHeaderSeconds,
                "response_body_seconds": timings.responseBodySeconds,
                "retirement_seconds": await runtime.lastStopSeconds,
                "audio_seconds": speech.duration,
                "audio_bytes": speech.wav.count,
                "output_sha256": sha256Hex(speech.wav),
                "total_seconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18]
    } catch {
        await runtime.stop()
        throw error
    }
}

func medians(_ runs: [[String: Any]], keys: [String]) -> [String: Double] {
    var result: [String: Double] = [:]
    for key in keys {
        let values = runs.compactMap { $0[key] as? Double }
        if let median = LiquidBenchmarkStatistics.median(values) { result[key] = median }
    }
    return result
}

do {
    if benchmarkOnly {
        guard try await assets.isReady() else { throw VoiceError.unavailable("Benchmark requires existing verified model assets; it never downloads them.") }
        let runs = max(1, min(12, Int(flagValue("--runs") ?? "") ?? 6))
        let seed = UInt32(flagValue("--seed") ?? "") ?? 20261102
        let text = flagValue("--text") ?? "The local voice test is complete. Your recording controls remain unchanged."
        guard !text.isEmpty, text.count <= 8_000 else { throw VoiceError.unavailable("Benchmark text is empty or exceeds 8,000 characters.") }
        let environment = benchmarkEnvironment()
        let stageKeys = ["startup_seconds", "request_seconds", "response_header_seconds",
                         "response_body_seconds", "validation_seconds", "retirement_seconds",
                         "total_seconds", "audio_seconds"]
        let compareName = flagValue("--compare")
        var variants: [String: Any] = [:]
        var pairs: [[String: Any]] = []
        if let compareName {
            guard let candidate = knownVariants[compareName] else {
                throw VoiceError.unavailable("Unknown benchmark variant '\(compareName)'. Known: \(knownVariants.keys.sorted().joined(separator: ", ")).")
            }
            var baselineRuns: [[String: Any]] = []
            var candidateRuns: [[String: Any]] = []
            for _ in 1...runs {
                // Randomized paired order so cache/thermal drift cannot favor one side.
                let order = ["baseline", candidate.name].shuffled()
                var results: [String: [String: Any]] = [:]
                for name in order {
                    let extra = name == "baseline" ? [] : candidate.extraServerArguments
                    let poll = name == "baseline" ? nil : candidate.healthPollInterval
                    results[name] = try await runOnce(runtimeDirectory: runtimeDirectory, assets: assets,
                                                     text: text, seed: seed, extraArguments: extra,
                                                     environment: environment, healthPollInterval: poll)
                }
                let baseline = results["baseline"]!; let contender = results[candidate.name]!
                baselineRuns.append(baseline); candidateRuns.append(contender)
                pairs.append(["order": order,
                              "delta_total_seconds": (contender["total_seconds"] as! Double) - (baseline["total_seconds"] as! Double),
                              "delta_header_seconds": (contender["response_header_seconds"] as! Double) - (baseline["response_header_seconds"] as! Double)])
            }
            for (name, runs) in [("baseline", baselineRuns), (candidate.name, candidateRuns)] {
                let extra = name == "baseline" ? [] : candidate.extraServerArguments
                let pollMs = name == "baseline" ? productionPollMs() : healthPollMs(candidate.healthPollInterval)
                let shas = Set(runs.compactMap { $0["output_sha256"] as? String })
                variants[name] = ["config": ["extra_server_arguments": extra,
                                             "server_environment_keys": environment.keys.sorted(),
                                             "health_poll_ms": pollMs],
                                  "runs": runs, "medians": medians(runs, keys: stageKeys),
                                  "output_matched": shas.count == 1]
            }
            // Cross-variant output check: same seed and text should synthesize identical bytes.
            let allShas = Set((baselineRuns + candidateRuns).compactMap { $0["output_sha256"] as? String })
            variants["cross_variant_output_matched"] = allShas.count == 1
        } else {
            var collected: [[String: Any]] = []
            for _ in 1...runs {
                collected.append(try await runOnce(runtimeDirectory: runtimeDirectory, assets: assets,
                                                  text: text, seed: seed, extraArguments: [],
                                                  environment: environment))
            }
            let shas = Set(collected.compactMap { $0["output_sha256"] as? String })
            variants["baseline"] = ["config": ["extra_server_arguments": [] as [String],
                                               "server_environment_keys": environment.keys.sorted(),
                                               "health_poll_ms": productionPollMs()],
                                    "runs": collected, "medians": medians(collected, keys: stageKeys),
                                    "output_matched": shas.count == 1]
        }
        let report: [String: Any] = ["mode": compareName == nil ? "baseline" : "compare",
            "text_chars": text.count, "text_sha256": sha256Hex(Data(text.utf8)), "tts_seed": seed,
            "server_version": serverVersion(runtimeDirectory.appendingPathComponent("llama-server")),
            "model_revision": LiquidAssets.revision,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "cpu_count": ProcessInfo.processInfo.processorCount,
            "uncontrolled": ["filesystem and driver cache state", "thermal state and background activity",
                             "whole-machine power and energy (no entitlement to measure)"],
            "variants": variants, "pairs": pairs,
            "note": "Fresh server process per run with verified assets and a fixed seed. Stage medians are directional only; run counts are too small for percentile claims. Timings do not measure audible onset and establish no speedup on their own."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fixtureDirectory.appendingPathComponent("tts-benchmark.json"))
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    }
    let runtime = LiquidRuntime(executable: runtimeDirectory.appendingPathComponent("llama-server"), assets: assets)
    do {
        try await assets.download()
        let started = ContinuousClock.now
    let speech = try await runtime.synthesize("The local voice test is complete. Your recording controls remain unchanged.")
    let synthesisSeconds = started.duration(to: .now).components
    try speech.wav.write(to: fixtureDirectory.appendingPathComponent("speech.wav"))
    let recognitionStart = ContinuousClock.now
    let text = try await runtime.transcribe(wav: speech.wav, translateToEnglish: false)
    let recognitionSeconds = recognitionStart.duration(to: .now).components
    guard text.lowercased().contains("voice"), text.lowercased().contains("recording") else {
        throw VoiceError.unavailable("Recognition did not recover the expected fixture words.")
    }
    await runtime.stop()
    let synthesis = Task { try await runtime.synthesize(String(repeating: "This long speech will be interrupted. ", count: 40)) }
    let inFlightDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    while await runtime.hasExited(), ContinuousClock.now < inFlightDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard !(await runtime.hasExited()) else { throw VoiceError.unavailable("Synthesis did not start before the cancellation check.") }
    let cancellationStart = ContinuousClock.now
    synthesis.cancel()
    await runtime.stop()
    if case .success = await synthesis.result {
        throw VoiceError.unavailable("Synthesis returned audio after cancellation.")
    }
    let cancellation = cancellationStart.duration(to: .now).components
    guard await runtime.hasExited() else { throw VoiceError.unavailable("Cancellation did not observe process exit.") }
    let report: [String: Any] = ["model_revision": LiquidAssets.revision, "runtime": "b11960 / 8642541b255bfb5dc39cd351a178be09013a55d6",
        "os": ProcessInfo.processInfo.operatingSystemVersionString, "memory_bytes": ProcessInfo.processInfo.physicalMemory,
        "tts_seconds": Double(synthesisSeconds.seconds) + Double(synthesisSeconds.attoseconds) / 1e18,
        "audio_seconds": speech.duration, "audio_bytes": speech.wav.count,
        "asr_seconds": Double(recognitionSeconds.seconds) + Double(recognitionSeconds.attoseconds) / 1e18,
        "transcript": text, "cancel_to_observed_exit_seconds": Double(cancellation.seconds) + Double(cancellation.attoseconds) / 1e18,
        "note": "Synthetic fixture only. Observed process exit does not prove immediate memory reclamation. Co-resident refinement pressure requires separate measurement."]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: fixtureDirectory.appendingPathComponent("report.json"))
    print(String(decoding: data, as: UTF8.self))
    } catch {
        await runtime.stop()
        throw error
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
