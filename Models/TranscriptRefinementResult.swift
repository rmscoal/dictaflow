import Foundation

nonisolated struct TranscriptRefinementResult: Codable, Equatable {
    let originalText: String
    let refinedText: String
    let model: RefinementModelDescriptor
    let mode: RefinementMode
    let completedAt: Date
    var toneFormatting: ToneFormattingResult? = nil
    var vocabularyReplacement: VocabularyReplacementResult? = nil

    var insertionText: String {
        (vocabularyReplacement?.text ?? toneFormatting?.text ?? refinedText).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
