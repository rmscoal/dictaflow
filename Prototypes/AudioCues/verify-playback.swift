// Standalone regression checks. Players read WAV metadata but never use audio hardware.
import AVFoundation
import Foundation

@MainActor
private final class SilentPlayer: AVAudioPlayer {
    var starts = 0
    var shouldPlay = true
    override var duration: TimeInterval { 0.01 }
    override func prepareToPlay() -> Bool { true }
    override func play() -> Bool {
        starts += 1
        return shouldPlay
    }
    override func stop() {}

    func finish() {
        delegate?.audioPlayerDidFinishPlaying?(self, successfully: true)
    }
}

@MainActor
private final class SilentRecordingPlayback: RecordingCuePlaybackProtocol {
    var isRecording = true
    var shouldFail = false
    var buffers: [SoundCuePlaybackBuffer] = []
    var completions: [@Sendable () -> Void] = []
    var stops = 0

    func playRecordingCue(_ buffer: SoundCuePlaybackBuffer, completion: @escaping @Sendable () -> Void) throws {
        guard isRecording, !shouldFail else { throw SoundCueServiceError.playbackFailed }
        buffers.append(buffer)
        completions.append(completion)
    }

    func stopRecordingCue() { stops += 1 }
}

@main
private struct PlaybackChecks {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Pass the built DictaFlow Dev.app path.")
        }

        // Launch/settings preloading must be silent, reuse its cache, and
        // replace that cache when the user chooses another sound style.
        var preparedPlayers: [String: SilentPlayer] = [:]
        var preparedCreations = 0
        let preparedService = SoundCueService(bundle: bundle) { url in
            let player = try SilentPlayer(contentsOf: url)
            preparedPlayers[url.deletingPathExtension().lastPathComponent] = player
            preparedCreations += 1
            return player
        }
        try preparedService.prepare(style: .softDigital)
        try preparedService.prepare(style: .softDigital)
        precondition(preparedCreations == 3, "Preparation recreated cached players")
        precondition(preparedPlayers.values.allSatisfy { $0.starts == 0 }, "Preparation played a cue")
        try preparedService.prepare(style: .mellowPulse)
        precondition(preparedCreations == 6, "Preparation did not replace the style cache")
        let preparedPreview = Task { try await preparedService.play(.error, style: .mellowPulse) }
        await wait { preparedPlayers["mellow-pulse-error"]?.starts == 1 }
        precondition(preparedCreations == 6, "Playback discarded the prepared cache")
        preparedPlayers["mellow-pulse-error"]?.finish()
        try await preparedPreview.value

        var players: [String: SilentPlayer] = [:]
        var creations = 0
        let service = SoundCueService(bundle: bundle) { url in
            let player = try SilentPlayer(contentsOf: url)
            players[url.deletingPathExtension().lastPathComponent] = player
            creations += 1
            return player
        }

        let start = Task { try await service.play(.startRecording, style: .softDigital) }
        await wait { players["soft-digital-start-recording"]?.starts == 1 }
        let stop = Task { try await service.play(.stopRecording, style: .softDigital) }
        await wait { players["soft-digital-stop-recording"] != nil }
        precondition(players["soft-digital-stop-recording"]?.starts == 0, "Cues overlapped")
        players["soft-digital-start-recording"]?.finish()
        try await start.value
        await wait { players["soft-digital-stop-recording"]?.starts == 1 }
        players["soft-digital-stop-recording"]?.finish()
        try await stop.value

        let repeated = Task { try await service.play(.startRecording, style: .softDigital) }
        await wait { players["soft-digital-start-recording"]?.starts == 2 }
        precondition(creations == 2, "Cached cue was recreated")
        let queued = Task { try await service.play(.stopRecording, style: .softDigital) }
        // Give the queued request a turn before stopping.
        try await Task.sleep(for: .milliseconds(10))
        service.stop()
        try await repeated.value
        try await queued.value
        precondition(players["soft-digital-stop-recording"]?.starts == 1, "Muted cue still played")

        let changed = Task { try await service.play(.startRecording, style: .mellowPulse) }
        await wait { players["mellow-pulse-start-recording"]?.starts == 1 }
        players["mellow-pulse-start-recording"]?.finish()
        try await changed.value
        precondition(creations == 3, "Style change did not replace the cache")

        players["mellow-pulse-start-recording"]?.shouldPlay = false
        do {
            try await service.play(.startRecording, style: .mellowPulse)
            fatalError("Failed playback was reported as successful")
        } catch SoundCueServiceError.playbackFailed {}

        // The fake never completes: a missing delegate callback must time out.
        do {
            try await service.play(.error, style: .mellowPulse)
            fatalError("Playback waited forever or succeeded without completion")
        } catch SoundCueServiceError.playbackFailed {}

        let recovered = Task { try await service.play(.stopRecording, style: .mellowPulse) }
        await wait { players["mellow-pulse-stop-recording"]?.starts == 1 }
        players["mellow-pulse-stop-recording"]?.finish()
        try await recovered.value

        let missing = SoundCueService(bundle: Bundle(for: SilentPlayer.self)) { _ in
            fatalError("Missing asset should fail before creating a player")
        }
        do {
            try await missing.play(.error, style: .softDigital)
            fatalError("Missing asset was accepted")
        } catch SoundCueServiceError.missingAsset {}

        let recording = SilentRecordingPlayback()
        let nativeService = SoundCueService(bundle: bundle, recordingPlayback: recording) { url in
            let player = try SilentPlayer(contentsOf: url)
            players[url.deletingPathExtension().lastPathComponent] = player
            return player
        }
        let nativeStart = Task { try await nativeService.play(.startRecording, style: .softDigital) }
        await wait { recording.buffers.count == 1 }
        precondition(recording.buffers[0].sampleRate == 48_000)
        precondition(recording.buffers[0].frameLength > 0)
        precondition(players["soft-digital-start-recording"]?.starts == 0,
                     "Start cue bypassed the voice-processing engine")
        let oldCompletion = recording.completions[0]
        nativeService.stop()
        try await nativeStart.value
        precondition(recording.stops == 1, "Mute did not stop native playback")

        let nextStart = Task { try await nativeService.play(.startRecording, style: .softDigital) }
        await wait { recording.buffers.count == 2 }
        precondition(recording.buffers[0] === recording.buffers[1], "Native cue was not cached")
        oldCompletion()
        try await Task.sleep(for: .milliseconds(10))
        precondition(recording.stops == 1, "A stale completion stopped the new cue")
        recording.completions[1]()
        try await nextStart.value

        recording.shouldFail = true
        do {
            try await nativeService.play(.startRecording, style: .softDigital)
            fatalError("Native playback failure was accepted")
        } catch SoundCueServiceError.playbackFailed {}
        precondition(players["soft-digital-start-recording"]?.starts == 0,
                     "Native failure fell back to unprocessed speaker playback")
        recording.shouldFail = false

        let newStyle = Task { try await nativeService.play(.startRecording, style: .mellowPulse) }
        await wait { recording.buffers.count == 3 }
        precondition(recording.buffers[0] !== recording.buffers[2], "Native style cache was not replaced")
        recording.completions[2]()
        try await newStyle.value

        recording.isRecording = false
        let preview = Task { try await nativeService.play(.startRecording, style: .mellowPulse) }
        await wait { players["mellow-pulse-start-recording"]?.starts == 1 }
        precondition(recording.buffers.count == 3, "Preview accessed the recording engine")
        players["mellow-pulse-start-recording"]?.finish()
        try await preview.value

        print("Passed: serialized playback, caching, mute, style change, failures, timeout, recovery, missing assets, native cue routing, stale completion, and standalone previews. No audio played.")
    }

    @MainActor
    private static func wait(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Playback check timed out")
    }
}
