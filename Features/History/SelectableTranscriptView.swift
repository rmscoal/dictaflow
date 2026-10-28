import AppKit
import SwiftUI

/// Read-only selectable transcript text. SwiftUI `Text` with
/// `textSelection(.enabled)` does not expose the selection to app code on the
/// deployment target, so this narrow AppKit bridge reports the selected
/// substring for History → Save correction.
struct SelectableTranscriptView: NSViewRepresentable {
    let text: String
    @Binding var selectedText: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.observeSelection(of: textView)
        apply(text: text, to: textView)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.parent = self
        if textView.string != text {
            apply(text: text, to: textView)
        }
        textView.textColor = .labelColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let layoutManager = nsView.layoutManager,
              let container = nsView.textContainer else { return nil }
        let width = proposal.width ?? 300
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = layoutManager.usedRect(for: container).height
        return CGSize(width: width, height: max(20, height))
    }

    private func apply(text: String, to textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        textView.textStorage?.setAttributedString(attributed)
        textView.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTranscriptView
        weak var textView: NSTextView?
        private var selectionObserver: NSObjectProtocol?

        init(parent: SelectableTranscriptView) { self.parent = parent }

        deinit {
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        }

        func observeSelection(of textView: NSTextView) {
            guard selectionObserver == nil else { return }
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: textView, queue: .main
            ) { [weak self] _ in
                self?.handleSelection()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            handleSelection()
        }

        private func handleSelection() {
            guard let textView else { return }
            let range = textView.selectedRange()
            let value: String
            if range.length > 0, let substring = Range(range, in: textView.string) {
                value = String(textView.string[substring]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                value = ""
            }
            // Keep the last meaningful selection as the Save correction
            // candidate. Opening the overflow menu can collapse the live
            // selection, and the parent resets the candidate explicitly when
            // the displayed result changes.
            guard !value.isEmpty, parent.selectedText != value else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.selectedText = value }
        }
    }
}
