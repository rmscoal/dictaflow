import Foundation

enum DictationRecordingState: Equatable {
    case idle
    case requestingPermission
    case recording(startedAt: Date, fileURL: URL)
    case stopping

    var isRecording: Bool {
        if case .recording = self {
            return true
        }

        return false
    }
}
