import Foundation

enum SoundCue: String, CaseIterable, Identifiable {
    case startRecording = "start-recording"
    case stopRecording = "stop-recording"
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startRecording: return "Start"
        case .stopRecording: return "Stop"
        case .error: return "Error"
        }
    }
}

enum SoundCueStyle: String, CaseIterable, Identifiable {
    case softDigital = "soft-digital"
    case mellowPulse = "mellow-pulse"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .softDigital: return "Soft Digital"
        case .mellowPulse: return "Mellow Pulse"
        }
    }
}
