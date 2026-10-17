import SwiftUI

struct HistoryPlaybackView: View {
    @ObservedObject var player: HistoryAudioPlayer
    let recordingDuration: TimeInterval
    let isLoading: Bool
    let available: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                if isLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
            }
                .buttonStyle(.bordered)
                .accessibilityLabel(isLoading ? "Loading Recording" : (player.isPlaying ? "Pause Recording" : "Play Recording"))
                .disabled(!available)
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                .disabled(player.duration == 0 || !available)
                .accessibilityLabel("Playback position")
            Text("\(formatDuration(player.position)) / \(formatDuration(player.duration > 0 ? player.duration : recordingDuration))")
                .font(.caption.monospacedDigit()).foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.vertical, 10)
    }
}

func formatDuration(_ duration: TimeInterval) -> String {
    let seconds = max(Int(duration), 0)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

func resultStatusTitle(_ status: HistoryAttemptStatus) -> String {
    switch status {
    case .succeeded: "Completed"
    case .failed: "Failed"
    case .interrupted: "Interrupted"
    case .running: "Processing"
    case .unprocessed: "Not processed"
    }
}
