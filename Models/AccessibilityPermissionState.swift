import Foundation

enum AccessibilityPermissionState: Equatable {
    case undetermined
    case granted
    case denied

    init(isGranted: Bool, hasRequestedBefore: Bool) {
        if isGranted {
            self = .granted
        } else if hasRequestedBefore {
            self = .denied
        } else {
            self = .undetermined
        }
    }

    var title: String {
        switch self {
        case .undetermined:
            return "Not Requested"
        case .granted:
            return "Allowed"
        case .denied:
            return "Needs Approval"
        }
    }

    var detailText: String {
        switch self {
        case .undetermined:
            return "DictaFlow will request Accessibility access the first time it needs to insert text into another app."
        case .granted:
            return "Accessibility access is available for direct insertion, paste fallback, and simulated typing."
        case .denied:
            return "Accessibility access is required to insert text into other apps automatically. Enable it in System Settings > Privacy & Security > Accessibility."
        }
    }
}
