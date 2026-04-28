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
            return "Fix punctuation, grammar, spacing, repeated words, harmless filler, and obvious structure without changing meaning."
        }
    }
}
