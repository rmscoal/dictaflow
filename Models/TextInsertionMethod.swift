import Foundation

enum TextInsertionMethod: String, Equatable {
    case accessibilityDirect
    case clipboardPaste
    case simulatedTyping
    case copyPanel

    var title: String {
        switch self {
        case .accessibilityDirect:
            return "Accessibility Insert"
        case .clipboardPaste:
            return "Clipboard Paste"
        case .simulatedTyping:
            return "Simulated Typing"
        case .copyPanel:
            return "Copy Panel"
        }
    }

    var detailText: String {
        switch self {
        case .accessibilityDirect:
            return "Inserted directly into the focused text field through Accessibility."
        case .clipboardPaste:
            return "Inserted by temporarily placing the transcript on the clipboard and triggering Paste."
        case .simulatedTyping:
            return "Inserted by typing the transcript into the target app."
        case .copyPanel:
            return "Copied to the clipboard and shown in a fallback panel for manual paste."
        }
    }
}
