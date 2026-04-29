import Foundation

enum RefinementMode: String, Codable, Equatable, CaseIterable {
    case smartCleanup

    var title: String {
        switch self {
        case .smartCleanup:
            return "Smart Cleanup"
        }
    }

    var detailText: String {
        switch self {
        case .smartCleanup:
            return "Fix grammar, punctuation, filler, false starts, self-corrections, awkward wording, and repeated meanings without changing intent."
        }
    }
}
