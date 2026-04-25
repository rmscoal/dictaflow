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
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window {
            return window
        }

        let hostingController = NSHostingController(rootView: ContentView(appState: appState))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "DictaFlow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = hostingController
        window.center()
        window.isOpaque = true
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DictaFlowMainWindowCompact")
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unifiedCompact
        window.delegate = self

        self.window = window
        return window
    }
}
