import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, permissions
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
