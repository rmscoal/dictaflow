import AgentVoice
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: dictaflow-audio-check RUNTIME_DIRECTORY FIXTURE_DIRECTORY\nDownloads 1.4 GB of pinned model assets and runs local TTS/ASR/cancellation. Does not play audio.\n".utf8))
    exit(2)
}
let runtimeDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
let assets = LiquidAssets(directory: fixtureDirectory.appendingPathComponent("models"))
let runtime = LiquidRuntime(executable: runtimeDirectory.appendingPathComponent("llama-server"), assets: assets)
do {
    try await assets.download()
    let started = ContinuousClock.now
    let speech = try await runtime.synthesize("The local voice test is complete. Your recording controls remain unchanged.")
    let synthesisSeconds = started.duration(to: .now).components
    try speech.wav.write(to: fixtureDirectory.appendingPathComponent("speech.wav"))
    let recognitionStart = ContinuousClock.now
    let text = try await runtime.transcribe(wav: speech.wav, english: true)
    let recognitionSeconds = recognitionStart.duration(to: .now).components
    guard text.lowercased().contains("voice"), text.lowercased().contains("recording") else {
        throw VoiceError.unavailable("Recognition did not recover the expected fixture words: \(text)")
    }
    let synthesis = Task { try await runtime.synthesize(String(repeating: "This long speech will be interrupted. ", count: 40)) }
    try await Task.sleep(for: .milliseconds(500))
    let cancellationStart = ContinuousClock.now
    synthesis.cancel()
    await runtime.stop()
    _ = try? await synthesis.value
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
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
