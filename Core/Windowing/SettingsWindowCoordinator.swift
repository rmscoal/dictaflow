import AppKit
import SwiftUI

@MainActor
final class SettingsWindowCoordinator: NSObject, SettingsWindowRouting, NSWindowDelegate {
    private let appState: DictaFlowAppState
    private var window: NSWindow?

    init(appState: DictaFlowAppState) {
        self.appState = appState
    }

    func showSettingsWindow() {
        let window = makeWindowIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        appState.settingsWindowDidOpen()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        appState.settingsWindowDidOpen()
    }

    func windowWillClose(_ notification: Notification) {
        appState.settingsWindowDidClose()
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window {
            return window
        }

        let hostingController = NSHostingController(rootView: SettingsView(appState: appState))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "DictaFlow Settings"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DictaFlowSettingsWindow")
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unifiedCompact
        window.delegate = self

        self.window = window
        return window
    }
}
