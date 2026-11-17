import Foundation

nonisolated struct WhisperTranscriptionResult: Codable, Equatable {
    let text: String
    let segments: [WhisperTranscriptionSegment]
    let detectedLanguageCode: String?
    let model: WhisperModelDescriptor?
    let taskMode: WhisperTaskMode
    let completedAt: Date
    var refinement: TranscriptRefinementResult? = nil
    var refinementStatus: TranscriptRefinementStatus = .disabled

    var toneFormatting: ToneFormattingResult? = nil
    var vocabularyReplacement: VocabularyReplacementResult? = nil
    var initialPromptExcludedTerms: [String]? = nil
    // Missing in older history rows means Whisper. Liquid results have no Whisper model.
    var recognitionProvider: SpeechRecognitionProvider? = nil

    var speechModelName: String {
        recognitionProvider == .liquid ? "Liquid LFM3-Audio-2B" : "Whisper \(model?.displayName ?? "Unknown")"
    }

    var insertionText: String {
        if let refinement {
            return refinement.insertionText
        }
        return (vocabularyReplacement?.text ?? toneFormatting?.text ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var detectedLanguageDisplayName: String {
        guard let detectedLanguageCode else {
            return "Unknown"
        }

        return Locale.current.localizedString(forLanguageCode: detectedLanguageCode)?.capitalized ?? detectedLanguageCode
    }
}
