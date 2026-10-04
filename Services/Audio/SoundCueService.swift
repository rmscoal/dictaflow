import AVFoundation
import Foundation

// Decode once, then keep PCM private and immutable. Unlike AVAudioPCMBuffer,
// this value can safely pass from the UI cache to the serial audio engine queue.
final class SoundCuePlaybackBuffer: @unchecked Sendable {
    private let pcm: AVAudioPCMBuffer
    var sampleRate: Double { pcm.format.sampleRate }
    var frameLength: AVAudioFrameCount { pcm.frameLength }

    init(contentsOf url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                        frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SoundCueServiceError.playbackFailed
        }
        try file.read(into: pcm)
        self.pcm = pcm
    }

    func schedule(on player: AVAudioPlayerNode, completion: @escaping @Sendable () -> Void) {
        player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { _ in completion() }
    }
}

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
        let recordingBuffer: SoundCuePlaybackBuffer?
        let continuation: CheckedContinuation<Void, Error>
    }

    private let bundle: Bundle
    private let makePlayer: (URL) throws -> AVAudioPlayer
    private weak var recordingPlayback: RecordingCuePlaybackProtocol?
    private var cachedStyle: SoundCueStyle?
    private var players: [SoundCue: AVAudioPlayer] = [:]
    private var recordingBuffers: [SoundCue: SoundCuePlaybackBuffer] = [:]
    private var pending: [Playback] = []
    private var active: Playback?
    private var playbackTimeout: Task<Void, Never>?

    init(
        bundle: Bundle = .main,
        recordingPlayback: RecordingCuePlaybackProtocol? = nil,
        makePlayer: @escaping (URL) throws -> AVAudioPlayer = { try AVAudioPlayer(contentsOf: $0) }
    ) {
        self.bundle = bundle
        self.makePlayer = makePlayer
        self.recordingPlayback = recordingPlayback
        super.init()
    }

    func play(_ cue: SoundCue, style: SoundCueStyle) async throws {
        updateCache(for: style)
        let player = try player(for: cue, style: style)
        let buffer = cue == .startRecording && recordingPlayback?.isRecording == true
            ? try recordingBuffer(for: cue, style: style) : nil
        try await withCheckedThrowingContinuation { continuation in
            pending.append(Playback(player: player, recordingBuffer: buffer, continuation: continuation))
            startNextPlayback()
        }
    }

    func prepare(style: SoundCueStyle) throws {
        updateCache(for: style)
        for cue in SoundCue.allCases { _ = try player(for: cue, style: style) }
        _ = try recordingBuffer(for: .startRecording, style: style)
    }

    func stop() {
        playbackTimeout?.cancel()
        playbackTimeout = nil
        let interrupted = active
        active = nil
        if let interrupted { stopPlayback(interrupted) }
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
        recordingBuffers.removeAll()
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

    private func recordingBuffer(for cue: SoundCue, style: SoundCueStyle) throws -> SoundCuePlaybackBuffer {
        if let buffer = recordingBuffers[cue] { return buffer }
        let url = try assetURL(for: cue, style: style)
        let buffer = try SoundCuePlaybackBuffer(contentsOf: url)
        recordingBuffers[cue] = buffer
        return buffer
    }

    private func startNextPlayback() {
        guard active == nil, !pending.isEmpty else { return }
        let playback = pending.removeFirst()
        active = playback
        if let buffer = playback.recordingBuffer {
            startRecordingPlayback(playback, buffer: buffer)
            return
        }
        playback.player.currentTime = 0
        guard playback.player.prepareToPlay(), playback.player.play() else {
            finishPlayback(id: playback.id, error: SoundCueServiceError.playbackFailed)
            return
        }
        scheduleTimeout(for: playback)
    }

    private func startRecordingPlayback(_ playback: Playback, buffer: SoundCuePlaybackBuffer) {
        Task { @MainActor [weak self] in
            guard let self, active?.id == playback.id else { return }
            do {
                guard let recordingPlayback else { throw SoundCueServiceError.playbackFailed }
                let id = playback.id
                try await recordingPlayback.playRecordingCue(buffer) { [weak self] in
                    Task { @MainActor [weak self] in self?.finishPlayback(id: id) }
                }
                guard active?.id == playback.id else { return }
                scheduleTimeout(for: playback)
            } catch {
                finishPlayback(id: playback.id, error: error)
            }
        }
    }

    private func scheduleTimeout(for playback: Playback) {
        // Native completion includes device latency. Give delayed routes time to
        // complete, but never leave volume restoration waiting indefinitely.
        let timeout = playback.player.duration + (playback.recordingBuffer == nil ? 0.5 : 2)
        playbackTimeout = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            self?.finishPlayback(id: playback.id, error: SoundCueServiceError.playbackFailed)
        }
    }

    private func stopPlayback(_ playback: Playback) {
        if playback.recordingBuffer != nil {
            recordingPlayback?.stopRecordingCue()
        } else {
            playback.player.stop()
        }
    }

    private func finishPlayback(id: UUID, error: Error? = nil) {
        guard let playback = active, playback.id == id else { return }
        playbackTimeout?.cancel()
        playbackTimeout = nil
        active = nil
        stopPlayback(playback)
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
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let active, active.recordingBuffer == nil,
                  ObjectIdentifier(active.player) == identifier else { return }
            finishPlayback(id: active.id, error: successfully ? nil : SoundCueServiceError.playbackFailed)
        }
    }
}
