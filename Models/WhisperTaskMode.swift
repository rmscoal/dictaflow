import Foundation

enum WhisperTaskMode: String, Codable, Equatable {
    case transcribe
    case translateToEnglish

    var title: String {
        switch self {
        case .transcribe:
            return "Transcribe"
        case .translateToEnglish:
            return "Translate to English"
        }
    }
}
