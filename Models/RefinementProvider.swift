import Foundation

nonisolated enum RefinementProvider: String, CaseIterable, Identifiable {
    case qwen, google, microsoft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .qwen: "Qwen"
        case .google: "Google Gemma"
        case .microsoft: "Microsoft Phi"
        }
    }
    var compactTitle: String {
        switch self {
        case .qwen: "Qwen"
        case .google: "Gemma"
        case .microsoft: "Microsoft"
        }
    }
    var iconName: String { "provider-" + rawValue }
}
