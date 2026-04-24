import Foundation

enum WhisperTaskMode: String, Codable, Equatable, CaseIterable {
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

    var detailText: String {
        switch self {
        case .transcribe:
            return "Keep the transcript in the spoken language."
        case .translateToEnglish:
            return "Translate supported source languages into English after local transcription."
        }
    }
}
