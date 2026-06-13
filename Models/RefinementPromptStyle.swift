import Foundation

enum RefinementPromptStyle: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case automatic
    case compact
    case standard

    nonisolated var id: String {
        rawValue
    }

    nonisolated var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .compact:
            return "Compact"
        case .standard:
            return "Standard"
        }
    }

    nonisolated var detailText: String {
        switch self {
        case .automatic:
            return "Choose compact or standard based on the selected refinement model."
        case .compact:
            return RefinementPromptProfile.compact.detailText
        case .standard:
            return RefinementPromptProfile.standard.detailText
        }
    }

    nonisolated func resolvedProfile(for model: RefinementModelDescriptor) -> RefinementPromptProfile {
        switch self {
        case .automatic:
            return model.defaultPromptProfile
        case .compact:
            return .compact
        case .standard:
            return .standard
        }
    }
}
