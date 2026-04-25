import Foundation

struct GlobalShortcutDescriptor: Equatable {
    let displayValue: String

    static let toggleDictation = GlobalShortcutDescriptor(displayValue: "Command + Shift + \\")
}
