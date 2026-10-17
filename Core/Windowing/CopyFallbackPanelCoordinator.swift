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
        PrivatePasteboardWriter.write(text, to: .general)
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
                .font(.system(size: 17, weight: .medium))

            Text(descriptionText)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(text)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(AppTheme.paperBorder, lineWidth: 1) }

            HStack {
                Button("Copy Again") {
                    onCopyAgain()
                }
                .buttonStyle(EmberButtonStyle(primary: true))

                Button("Close") {
                    onClose()
                }
                .buttonStyle(EmberButtonStyle())
            }
        }
        .padding(22)
        .frame(minWidth: 460, minHeight: 320)
        .foregroundStyle(AppTheme.primaryText).background(AppTheme.background)
    }

    private var descriptionText: String {
        if let targetApplicationName {
            return "The transcript is already on the clipboard. Paste it manually into \(targetApplicationName)."
        }

        return "The transcript is already on the clipboard. Paste it manually into the target app."
    }
}
