import Foundation

nonisolated enum TextTone: String, Codable, CaseIterable, Identifiable {
    case original, casual, balanced, formal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

nonisolated enum DictationSettingsTab: String, CaseIterable, Identifiable {
    case transcription, refinement, tone
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Stores the exact output, so future rule changes cannot alter saved results.
nonisolated struct ToneFormattingResult: Codable, Equatable {
    let tone: TextTone
    let formatterVersion: Int
    let text: String
}
