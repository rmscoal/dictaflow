import Foundation

enum MainWindowPage: String, CaseIterable, Identifiable {
    case dictation, history, settings, updates
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .dictation: "waveform"
        case .history: "clock"
        case .settings: "slider.horizontal.3"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

struct ModelPickerPresentation: Identifiable {
    enum Kind: String { case speech, refinement }
    let kind: Kind
    var modelIdentifier: String?
    var id: Kind { kind }
}

struct InterfaceIssue: Identifiable {
    enum Severity { case information, error }
    let id = UUID()
    let title: String
    let message: String
    var severity: Severity = .error
}
