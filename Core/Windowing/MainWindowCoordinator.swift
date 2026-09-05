import AppKit
import SwiftUI

@MainActor
final class MainWindowCoordinator: NSObject, MainWindowRouting, NSWindowDelegate {
    private let appState: DictaFlowAppState
    private var window: NSWindow?

    init(appState: DictaFlowAppState) {
        self.appState = appState
    }

    func showMainWindow() {
        // Promote to a regular app so the main window joins the Dock and Cmd-Tab
        // while it is open. The app otherwise stays an accessory agent.
        NSApp.setActivationPolicy(.regular)

        let window = makeWindowIfNeeded()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        appState.mainWindowDidOpen()
    }

    func closeMainWindow() {
        guard let window, window.isVisible else {
            return
        }

        window.performClose(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        appState.mainWindowDidOpen()
    }

    func windowWillClose(_ notification: Notification) {
        appState.mainWindowDidClose()

        // Return to accessory policy so the app leaves the Dock and Cmd-Tab
        // once the main window is gone.
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window {
            return window
        }

        let hostingController = NSHostingController(rootView: ContentView(appState: appState))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "DictaFlow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 660, height: 520)
        window.center()
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.090, green: 0.098, blue: 0.114, alpha: 1)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DictaFlowMainWindowSidebar")
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unifiedCompact
        window.delegate = self

        self.window = window
        return window
    }
}
