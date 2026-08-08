import AppKit
import Carbon
import SwiftUI

struct GlobalShortcutCaptureView: NSViewRepresentable {
    let isCapturing: Bool
    let onShortcut: (GlobalShortcutDescriptor?) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> GlobalShortcutCaptureNSView {
        let view = GlobalShortcutCaptureNSView()
        view.isCapturing = isCapturing
        view.onShortcut = onShortcut
        view.onCancel = onCancel
        focusIfNeeded(view)
        return view
    }

    func updateNSView(_ nsView: GlobalShortcutCaptureNSView, context: Context) {
        nsView.isCapturing = isCapturing
        nsView.onShortcut = onShortcut
        nsView.onCancel = onCancel

        if isCapturing {
            focusIfNeeded(nsView)
        }
    }

    private func focusIfNeeded(_ view: GlobalShortcutCaptureNSView) {
        DispatchQueue.main.async { [weak view] in
            guard let view, view.isCapturing else {
                return
            }

            view.window?.makeFirstResponder(view)
        }
    }
}

final class GlobalShortcutCaptureNSView: NSView {
    var isCapturing = false
    var onShortcut: ((GlobalShortcutDescriptor?) -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing else {
            return super.performKeyEquivalent(with: event)
        }

        handleKeyEvent(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else {
            super.keyDown(with: event)
            return
        }

        handleKeyEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        guard isCapturing else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let modifierFlags = event.modifierFlags.intersection(Self.shortcutModifierFlags)
        if event.keyCode == UInt16(kVK_Escape), modifierFlags.isEmpty {
            onCancel?()
            return
        }

        onShortcut?(GlobalShortcutDescriptor(event: event))
    }

    private static let shortcutModifierFlags: NSEvent.ModifierFlags = [
        .command,
        .option,
        .control,
        .shift
    ]
}

private extension GlobalShortcutDescriptor {
    init?(event: NSEvent) {
        let modifierFlags = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        let carbonModifierFlags = Self.carbonModifierFlags(from: modifierFlags)

        guard carbonModifierFlags != 0 else {
            return nil
        }

        self.init(
            keyCode: UInt32(event.keyCode),
            modifierFlags: carbonModifierFlags,
            keyDisplayValue: Self.keyDisplayValue(for: event)
        )
    }

    static func carbonModifierFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0

        if flags.contains(.command) {
            result |= UInt32(cmdKey)
        }

        if flags.contains(.option) {
            result |= UInt32(optionKey)
        }

        if flags.contains(.control) {
            result |= UInt32(controlKey)
        }

        if flags.contains(.shift) {
            result |= UInt32(shiftKey)
        }

        return result
    }

    static func keyDisplayValue(for event: NSEvent) -> String {
        switch event.keyCode {
        case UInt16(kVK_Return):
            return "Return"
        case UInt16(kVK_Tab):
            return "Tab"
        case UInt16(kVK_Space):
            return "Space"
        case UInt16(kVK_Delete):
            return "Delete"
        case UInt16(kVK_ForwardDelete):
            return "Forward Delete"
        case UInt16(kVK_Escape):
            return "Escape"
        case UInt16(kVK_LeftArrow):
            return "Left Arrow"
        case UInt16(kVK_RightArrow):
            return "Right Arrow"
        case UInt16(kVK_DownArrow):
            return "Down Arrow"
        case UInt16(kVK_UpArrow):
            return "Up Arrow"
        case UInt16(kVK_Home):
            return "Home"
        case UInt16(kVK_End):
            return "End"
        case UInt16(kVK_PageUp):
            return "Page Up"
        case UInt16(kVK_PageDown):
            return "Page Down"
        case UInt16(kVK_Help):
            return "Help"
        case UInt16(kVK_F1):
            return "F1"
        case UInt16(kVK_F2):
            return "F2"
        case UInt16(kVK_F3):
            return "F3"
        case UInt16(kVK_F4):
            return "F4"
        case UInt16(kVK_F5):
            return "F5"
        case UInt16(kVK_F6):
            return "F6"
        case UInt16(kVK_F7):
            return "F7"
        case UInt16(kVK_F8):
            return "F8"
        case UInt16(kVK_F9):
            return "F9"
        case UInt16(kVK_F10):
            return "F10"
        case UInt16(kVK_F11):
            return "F11"
        case UInt16(kVK_F12):
            return "F12"
        case UInt16(kVK_F13):
            return "F13"
        case UInt16(kVK_F14):
            return "F14"
        case UInt16(kVK_F15):
            return "F15"
        case UInt16(kVK_F16):
            return "F16"
        case UInt16(kVK_F17):
            return "F17"
        case UInt16(kVK_F18):
            return "F18"
        case UInt16(kVK_F19):
            return "F19"
        case UInt16(kVK_F20):
            return "F20"
        case UInt16(kVK_ANSI_Grave):
            return "`"
        case UInt16(kVK_ANSI_Minus):
            return "-"
        case UInt16(kVK_ANSI_Equal):
            return "="
        case UInt16(kVK_ANSI_LeftBracket):
            return "["
        case UInt16(kVK_ANSI_RightBracket):
            return "]"
        case UInt16(kVK_ANSI_Semicolon):
            return ";"
        case UInt16(kVK_ANSI_Quote):
            return "'"
        case UInt16(kVK_ANSI_Comma):
            return ","
        case UInt16(kVK_ANSI_Period):
            return "."
        case UInt16(kVK_ANSI_Slash):
            return "/"
        case UInt16(kVK_ANSI_Backslash):
            return "\\"
        default:
            let characters = event.charactersIgnoringModifiers ?? ""
            let trimmedCharacters = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedCharacters.isEmpty ? "Key \(event.keyCode)" : trimmedCharacters.uppercased()
        }
    }
}
