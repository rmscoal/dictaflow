import Foundation

enum WhisperInputLanguage: Codable, Equatable, Hashable {
    case automatic
    case languageCode(String)

    var displayName: String {
        switch self {
        case .automatic:
            return "Auto Detect"
        case .languageCode(let code):
            return WhisperLanguageCatalog.supportedLanguages
                .first(where: { $0.code == code })?
                .displayName
                ?? Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized
                ?? code.uppercased()
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

    var detailText: String {
        switch self {
        case .automatic:
            return "Whisper will auto-detect the spoken language for each recording."
        case .languageCode:
            return "Whisper will skip auto-detection and decode using the selected source language."
        }
    }
}
