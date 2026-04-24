import Foundation

enum TextInsertionState: Equatable {
    case idle
    case requestingAccessibilityPermission(targetApplicationName: String?)
    case inserting(targetApplicationName: String?)

    var isBusy: Bool {
        switch self {
        case .idle:
            return false
        case .requestingAccessibilityPermission, .inserting:
            return true
        }
    }
}
