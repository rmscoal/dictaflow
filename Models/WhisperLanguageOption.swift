import Foundation
import whisper

struct WhisperLanguageOption: Identifiable, Hashable {
    let code: String
    let whisperName: String

    var id: String { code }

    var displayName: String {
        Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized
            ?? whisperName.capitalized
    }

    var inputLanguage: WhisperInputLanguage {
        .languageCode(code)
    }
}

enum WhisperLanguageCatalog {
    private static let commonCodes = [
        "en", "id", "zh", "ja", "ko", "fr", "de", "es", "pt", "ru"
    ]

    static let supportedLanguages: [WhisperLanguageOption] = {
        let maximumLanguageIdentifier = whisper_lang_max_id()
        guard maximumLanguageIdentifier >= 0 else {
            return []
        }

        return (0...maximumLanguageIdentifier)
            .compactMap { identifier in
                guard
                    let codePointer = whisper_lang_str(identifier),
                    let namePointer = whisper_lang_str_full(identifier)
                else {
                    return nil
                }

                return WhisperLanguageOption(
                    code: String(cString: codePointer),
                    whisperName: String(cString: namePointer)
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }()

    static let commonLanguages: [WhisperLanguageOption] = commonCodes.compactMap { code in
        supportedLanguages.first(where: { $0.code == code })
    }

    static let additionalLanguages: [WhisperLanguageOption] = supportedLanguages.filter { option in
        !commonCodes.contains(option.code)
    }
}
