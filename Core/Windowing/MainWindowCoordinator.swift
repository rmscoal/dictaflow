import AppKit
import SwiftUI

@MainActor
final class MainWindowCoordinator: NSObject, MainWindowRouting, NSWindowDelegate {
    private let appState: DictaFlowAppState
    private var window: NSWindow?
    private var backdropView: NSVisualEffectView?

    init(appState: DictaFlowAppState) {
        self.appState = appState
    }

    func showMainWindow() {
        // Promote to a regular app so the main window joins the Dock and Cmd-Tab
        // while it is open. The app otherwise stays an accessory agent.
        NSApp.setActivationPolicy(.regular)

        let window = makeWindowIfNeeded()
        updateBackdropAppearance()

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
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1168, height: 868)
        let initialSize = NSSize(width: min(1120, max(660, visibleFrame.width - 48)),
                                 height: min(820, max(520, visibleFrame.height - 48)))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Omdo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = makeWindowContent(hostingController)
        window.minSize = NSSize(width: 660, height: 520)
        window.center()
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DictaFlowMainWindowSidebar")
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unifiedCompact
        window.delegate = self
        self.window = window
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reduceTransparencyDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        return window
    }

    private func makeWindowContent(_ hostingController: NSHostingController<ContentView>) -> NSViewController {
        let controller = NSViewController()
        let container = NSView()
        controller.view = container

        // Keep the material and the SwiftUI surface as siblings so the
        // material stays behind the content even when it is hidden.
        let backdrop = OmdoWindowBackdrop.makeView()
        backdropView = backdrop

        controller.addChild(hostingController)
        for view in [backdrop, hostingController.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        return controller
    }

    @objc private nonisolated func reduceTransparencyDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.updateBackdropAppearance() }
    }

    private func updateBackdropAppearance() {
        guard let window else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        backdropView?.isHidden = reduce
        window.isOpaque = reduce
        window.backgroundColor = reduce ? AppTheme.windowBackgroundColor : .clear
        window.invalidateShadow()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
