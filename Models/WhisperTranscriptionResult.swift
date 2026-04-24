import Foundation

struct WhisperTranscriptionResult: Equatable {
    let text: String
    let segments: [WhisperTranscriptionSegment]
    let detectedLanguageCode: String?
    let model: WhisperModelDescriptor
    let taskMode: WhisperTaskMode
    let completedAt: Date

    var detectedLanguageDisplayName: String {
        guard let detectedLanguageCode else {
            return "Unknown"
        }

        return Locale.current.localizedString(forLanguageCode: detectedLanguageCode)?.capitalized ?? detectedLanguageCode
    }
}
