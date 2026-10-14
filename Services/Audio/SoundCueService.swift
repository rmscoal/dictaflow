import AVFoundation
import Foundation

@MainActor
protocol SoundCueServiceProtocol: AnyObject {
    func prepare(style: SoundCueStyle) throws
    func play(_ cue: SoundCue, style: SoundCueStyle) async throws
    func stop()
}

extension SoundCueServiceProtocol {
    func prepare(style: SoundCueStyle) throws {}
}

enum SoundCueServiceError: LocalizedError {
    case missingAsset
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .missingAsset:
            return "A sound cue is missing. Reinstall DictaFlow to restore its sound files."
        case .playbackFailed:
            return "The sound cue could not play. Check your Mac's sound output or turn off sound cues in Dictation settings."
        }
    }
}

@MainActor
final class SoundCueService: NSObject, AVAudioPlayerDelegate, SoundCueServiceProtocol {
    private struct Playback {
        let id = UUID()
        let player: AVAudioPlayer
        let continuation: CheckedContinuation<Void, Error>
    }

    private let bundle: Bundle
    private let makePlayer: (URL) throws -> AVAudioPlayer
    private var cachedStyle: SoundCueStyle?
    private var players: [SoundCue: AVAudioPlayer] = [:]
    private var pending: [Playback] = []
    private var active: Playback?
    private var playbackTimeout: Task<Void, Never>?

    init(
        bundle: Bundle = .main,
        makePlayer: @escaping (URL) throws -> AVAudioPlayer = { try AVAudioPlayer(contentsOf: $0) }
    ) {
        self.bundle = bundle
        self.makePlayer = makePlayer
        super.init()
    }

    func play(_ cue: SoundCue, style: SoundCueStyle) async throws {
        updateCache(for: style)
        let player = try player(for: cue, style: style)
        // Reserve the preloaded player for this playback only. AVAudioPlayer
        // callbacks identify the player, not a playback session; reusing one
        // would let a delayed callback complete a newer request.
        players.removeValue(forKey: cue)
        try await withCheckedThrowingContinuation { continuation in
            pending.append(Playback(player: player, continuation: continuation))
            startNextPlayback()
        }
    }

    func prepare(style: SoundCueStyle) throws {
        updateCache(for: style)
        for cue in SoundCue.allCases { _ = try player(for: cue, style: style) }
    }

    func stop() {
        playbackTimeout?.cancel()
        playbackTimeout = nil
        let interrupted = active
        active = nil
        interrupted?.player.stop()
        interrupted?.continuation.resume()
        let cancelled = pending
        pending.removeAll()
        for playback in cancelled {
            playback.continuation.resume()
        }
    }

    private func updateCache(for style: SoundCueStyle) {
        guard cachedStyle != style else { return }
        stop()
        players.removeAll()
        cachedStyle = style
    }

    private func assetURL(for cue: SoundCue, style: SoundCueStyle) throws -> URL {
        let name = "\(style.rawValue)-\(cue.rawValue)"
        guard let url = bundle.url(forResource: name, withExtension: "wav") else {
            throw SoundCueServiceError.missingAsset
        }
        return url
    }

    private func player(for cue: SoundCue, style: SoundCueStyle) throws -> AVAudioPlayer {
        if let player = players[cue] {
            return player
        }
        let url = try assetURL(for: cue, style: style)
        let player = try makePlayer(url)
        player.delegate = self
        players[cue] = player
        return player
    }

    private func startNextPlayback() {
        guard active == nil, !pending.isEmpty else { return }
        let playback = pending.removeFirst()
        active = playback
        playback.player.currentTime = 0
        guard playback.player.prepareToPlay(), playback.player.play() else {
            finishPlayback(id: playback.id, error: SoundCueServiceError.playbackFailed)
            return
        }
        scheduleTimeout(for: playback)
    }

    private func scheduleTimeout(for playback: Playback) {
        // Native completion includes device latency. Give delayed routes time to
        // complete, but never leave volume restoration waiting indefinitely.
        let timeout = playback.player.duration + 0.5
        playbackTimeout = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            self?.finishPlayback(id: playback.id, error: SoundCueServiceError.playbackFailed)
        }
    }

    private func finishPlayback(id: UUID, error: Error? = nil) {
        guard let playback = active, playback.id == id else { return }
        playbackTimeout?.cancel()
        playbackTimeout = nil
        active = nil
        playback.player.stop()
        if let error {
            playback.continuation.resume(throwing: error)
        } else {
            playback.continuation.resume()
        }
        startNextPlayback()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        reportCompletion(player, successfully: flag)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        reportCompletion(player, successfully: false)
    }

    private nonisolated func reportCompletion(_ player: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor [weak self] in
            guard let self, let active,
                  active.player === player else { return }
            finishPlayback(id: active.id, error: successfully ? nil : SoundCueServiceError.playbackFailed)
        }
    }
}
