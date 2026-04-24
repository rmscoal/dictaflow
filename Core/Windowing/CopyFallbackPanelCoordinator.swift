import AppKit
import SwiftUI

@MainActor
final class CopyFallbackPanelCoordinator {
    private var panel: NSPanel?

    func show(text: String, targetApplicationName: String?) {
        let panel = makePanelIfNeeded()
        let rootView = CopyFallbackPanelView(
            text: text,
            targetApplicationName: targetApplicationName,
            onCopyAgain: { [weak self] in
                self?.copyToPasteboard(text)
            },
            onClose: { [weak self] in
                self?.panel?.orderOut(nil)
            }
        )

        panel.contentViewController = NSHostingController(rootView: rootView)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.title = "Copy Transcript"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false

        self.panel = panel
        return panel
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct CopyFallbackPanelView: View {
    let text: String
    let targetApplicationName: String?
    let onCopyAgain: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DictaFlow couldn’t insert the transcript automatically.")
                .font(.headline)

            Text(descriptionText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Copy Again") {
                    onCopyAgain()
                }
                .buttonStyle(.borderedProminent)

                Button("Close") {
                    onClose()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 320)
    }

    private var descriptionText: String {
        if let targetApplicationName {
            return "The transcript is already on the clipboard. Paste it manually into \(targetApplicationName)."
        }

        return "The transcript is already on the clipboard. Paste it manually into the target app."
    }
}
