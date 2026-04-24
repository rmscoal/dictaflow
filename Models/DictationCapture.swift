import Foundation

struct DictationCapture: Equatable {
    let fileURL: URL
    let duration: TimeInterval
    let capturedAt: Date

    var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 60 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: duration) ?? String(format: "%.1fs", duration)
    }
}
