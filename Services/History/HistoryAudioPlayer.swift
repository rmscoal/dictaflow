import AVFoundation
import Combine
import Foundation

@MainActor
final class HistoryAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var onFinished: (() -> Void)?

    deinit { timer?.invalidate() }

    func play(url: URL) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        guard player.prepareToPlay(), player.play() else { throw HistoryStoreError.invalidRecording }
        self.player = player
        duration = player.duration
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
            }
        }
    }

    func togglePause() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else { isPlaying = player.play() }
    }

    func seek(to value: TimeInterval) {
        player?.currentTime = min(max(value, 0), duration)
        position = player?.currentTime ?? 0
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        position = 0
        duration = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinished?() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onFinished?() }
    }
}
