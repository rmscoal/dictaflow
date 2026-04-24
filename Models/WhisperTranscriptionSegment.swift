import Foundation

struct WhisperTranscriptionSegment: Equatable, Identifiable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    var id: String {
        "\(startTime)-\(endTime)-\(text)"
    }
}
