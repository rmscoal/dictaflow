import Foundation

nonisolated enum RefinementProvider: String, CaseIterable, Identifiable {
    case qwen, meta, google, microsoft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .qwen: "Qwen"
        case .meta: "Meta Llama"
        case .google: "Google Gemma"
        case .microsoft: "Microsoft Phi"
        }
    }
    var compactTitle: String {
        switch self {
        case .qwen: "Qwen"
        case .meta: "Meta"
        case .google: "Gemma"
        case .microsoft: "Microsoft"
        }
    }
    var iconName: String { "provider-" + rawValue }
}
