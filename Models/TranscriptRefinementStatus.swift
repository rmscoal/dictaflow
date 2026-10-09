import Foundation

nonisolated enum TranscriptRefinementStatus: Codable, Equatable {
    case disabled
    case skipped(reason: String)
    case succeeded(model: RefinementModelDescriptor, mode: RefinementMode, completedAt: Date)
    case failed(model: RefinementModelDescriptor, errorMessage: String, completedAt: Date)
}
