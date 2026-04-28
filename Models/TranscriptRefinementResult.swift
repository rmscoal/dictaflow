import Foundation

struct TranscriptRefinementResult: Equatable {
    let originalText: String
    let refinedText: String
    let model: RefinementModelDescriptor
    let mode: RefinementMode
    let completedAt: Date
}
