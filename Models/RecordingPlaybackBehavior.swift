import Foundation

enum RecordingPlaybackBehavior: String, Codable, Equatable, CaseIterable {
    case unchanged
    case lowerSystemVolume

    static let `default` = RecordingPlaybackBehavior.unchanged

    var title: String {
        switch self {
        case .unchanged:
            return "Leave Playback Unchanged"
        case .lowerSystemVolume:
            return "Lower System Volume"
        }
    }

    var detailText: String {
        switch self {
        case .unchanged:
            return "Music and other system audio continue at their current volume while DictaFlow records."
        case .lowerSystemVolume:
            return "Temporarily lowers the default output volume while recording, then restores it afterward."
        }
    }
}
