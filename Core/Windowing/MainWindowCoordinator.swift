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
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "DictaFlow"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DictaFlowMainWindow")
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unifiedCompact
        window.delegate = self

        self.window = window
        return window
    }
}
