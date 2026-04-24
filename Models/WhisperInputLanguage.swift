import Foundation

enum WhisperInputLanguage: Codable, Equatable {
    case automatic
    case languageCode(String)

    var displayName: String {
        switch self {
        case .automatic:
            return "Auto Detect"
        case .languageCode(let code):
            return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
        }
    }

    var whisperCode: String? {
        switch self {
        case .automatic:
            return nil
        case .languageCode(let code):
            return code
        }
    }
}
