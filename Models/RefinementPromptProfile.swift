import Foundation

enum RefinementPromptProfile: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case compact
    case standard

    nonisolated var id: String {
        rawValue
    }

    nonisolated var title: String {
        switch self {
        case .compact:
            return "Compact"
        case .standard:
            return "Standard"
        }
    }

    nonisolated var detailText: String {
        switch self {
        case .compact:
            return "Shorter instructions for smaller refinement models."
        case .standard:
            return "Full instructions for larger refinement models."
        }
    }

    nonisolated var promptFilename: String {
        "refinement-\(rawValue).txt"
    }
}
