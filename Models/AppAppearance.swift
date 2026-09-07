import Foundation

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var detail: String {
        switch self {
        case .system: "Changes automatically with your Mac’s appearance."
        case .light: "Always uses light appearance, regardless of your Mac’s setting."
        case .dark: "Always uses dark appearance, regardless of your Mac’s setting."
        }
    }
}
