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
        var failNextPlayer = false
        let service = SoundCueService(bundle: bundle) { url in
            let player = try SilentPlayer(contentsOf: url)
            player.shouldPlay = !failNextPlayer
            failNextPlayer = false
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
        await wait { creations == 3 && players["soft-digital-start-recording"]?.starts == 1 }
        let queued = Task { try await service.play(.stopRecording, style: .softDigital) }
        await wait { creations == 4 && players["soft-digital-stop-recording"] != nil }
        precondition(players["soft-digital-stop-recording"]?.starts == 0, "Queued cue started before stop")
        service.stop()
        try await repeated.value
        try await queued.value
        precondition(players["soft-digital-stop-recording"]?.starts == 0, "Muted cue still played")

        let changed = Task { try await service.play(.startRecording, style: .mellowPulse) }
        await wait { players["mellow-pulse-start-recording"]?.starts == 1 }
        players["mellow-pulse-start-recording"]?.finish()
        try await changed.value
        precondition(creations == 5, "Style change did not create its own player")

        failNextPlayer = true
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

        print("Passed: serialized playback, caching, mute, style change, failures, timeout, recovery, and missing assets. No audio played.")
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
