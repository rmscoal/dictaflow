import Foundation

enum MicrophonePermissionState: Equatable {
    case undetermined
    case granted
    case denied
    case restricted

    var title: String {
        switch self {
        case .undetermined:
            return "Not Requested"
        case .granted:
            return "Allowed"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        }
    }

    var detailText: String {
        switch self {
        case .undetermined:
            return "DictaFlow will request microphone access the first time you start dictation."
        case .granted:
            return "Microphone access is available for local recording."
        case .denied:
            return "Microphone access is denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .restricted:
            return "Microphone access is restricted by macOS or device policy."
        }
    }
}
