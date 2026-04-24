import Foundation

struct TextInsertionResult: Equatable {
    let text: String
    let method: TextInsertionMethod
    let targetApplicationName: String?
    let completedAt: Date

    var summaryText: String {
        let targetText = targetApplicationName ?? "the target app"
        switch method {
        case .accessibilityDirect, .clipboardPaste, .simulatedTyping:
            return "Inserted into \(targetText) via \(method.title) at \(completedAt.formatted(date: .omitted, time: .standard))."
        case .copyPanel:
            return "Copied for manual paste into \(targetText) at \(completedAt.formatted(date: .omitted, time: .standard))."
        }
    }
}
