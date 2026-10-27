import Foundation

nonisolated enum TextTone: String, Codable, CaseIterable, Identifiable {
    case original, casual, balanced, formal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

nonisolated enum DictationSettingsTab: String, CaseIterable, Identifiable {
    case transcription, refinement
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

extension TextTone {
    /// Final formatting slider position. Legacy `.balanced` shares the
    /// no-op behavior of `.original`, so it maps to the center position.
    var finalFormattingPosition: Int {
        switch self {
        case .casual: 0
        case .original, .balanced: 1
        case .formal: 2
        }
    }

    /// The tone saved for a deliberate Final formatting selection.
    static func finalFormattingTone(at position: Int) -> TextTone {
        switch position {
        case ..<1: .casual
        case 1: .original
        default: .formal
        }
    }

    /// Visible Final formatting label for this tone.
    var finalFormattingTitle: String {
        switch self {
        case .casual: "Casual"
        case .original, .balanced: "Original"
        case .formal: "Formal"
        }
    }
}

/// Stores the exact output, so future rule changes cannot alter saved results.
nonisolated struct ToneFormattingResult: Codable, Equatable {
    let tone: TextTone
    let formatterVersion: Int
    let text: String
}
