import Foundation

nonisolated struct TranscriptRefinementResult: Codable, Equatable {
    let originalText: String
    let refinedText: String
    let model: RefinementModelDescriptor
    let mode: RefinementMode
    let completedAt: Date
    var toneFormatting: ToneFormattingResult? = nil

    var insertionText: String {
        (toneFormatting?.text ?? refinedText).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
