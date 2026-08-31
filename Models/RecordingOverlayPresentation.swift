import Foundation

struct RecordingOverlayPresentation: Equatable {
    enum Phase: Equatable {
        case requestingPermission
        case recording
        case downloadingModel
        case transcribing
        case refining
        case requestingAccessibilityPermission
        case inserting
    }

    let phase: Phase
    let title: String
    let detail: String
    let audioLevel: Double

    var isCancellable: Bool {
        phase == .recording
    }
}
