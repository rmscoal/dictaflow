import Carbon
import Foundation

struct GlobalShortcutDescriptor: Codable, Equatable {
    struct DisplayPart: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String?
    }

    let keyCode: UInt32
    let modifierFlags: UInt32
    let keyDisplayValue: String

    init(keyCode: UInt32, modifierFlags: UInt32, keyDisplayValue: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.keyDisplayValue = keyDisplayValue
    }

    static let toggleDictation = GlobalShortcutDescriptor(
        keyCode: UInt32(kVK_ANSI_Backslash),
        modifierFlags: UInt32(cmdKey | shiftKey),
        keyDisplayValue: "\\"
    )

    var isValid: Bool {
        let supportedModifierFlags = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return !keyDisplayValue.isEmpty
            && modifierFlags != 0
            && (modifierFlags & ~supportedModifierFlags) == 0
    }

    var displayParts: [DisplayPart] {
        var parts: [DisplayPart] = []

        if containsModifier(UInt32(cmdKey)) {
            parts.append(DisplayPart(id: "command", title: "Command", symbol: "command"))
        }

        if containsModifier(UInt32(optionKey)) {
            parts.append(DisplayPart(id: "option", title: "Option", symbol: "option"))
        }

        if containsModifier(UInt32(controlKey)) {
            parts.append(DisplayPart(id: "control", title: "Control", symbol: "control"))
        }

        if containsModifier(UInt32(shiftKey)) {
            parts.append(DisplayPart(id: "shift", title: "Shift", symbol: "shift"))
        }

        parts.append(DisplayPart(id: "key", title: keyDisplayValue, symbol: nil))
        return parts
    }

    var displayValue: String {
        displayParts.map(\.title).joined(separator: " + ")
    }

    private func containsModifier(_ modifier: UInt32) -> Bool {
        modifierFlags & UInt32(modifier) != 0
    }
}
