import SwiftUI

/// Reports the columns after native scrolling has been idle for 150 milliseconds.
struct ScrollViewportPositionReader: NSViewRepresentable {
    var onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> PositionView { PositionView() }

    func updateNSView(_ view: PositionView, context: Context) {
        view.onChange = onChange
    }

    final class PositionView: NSView {
        var onChange: ((CGRect) -> Void)?
        private weak var clipView: NSClipView?
        private var pendingUpdate: DispatchWorkItem?
        private var lastObservedFrame: CGRect?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            pendingUpdate?.cancel()
            pendingUpdate = nil
            lastObservedFrame = nil
            NotificationCenter.default.removeObserver(self)
            clipView = window == nil ? nil : enclosingScrollView?.contentView
            if let clipView {
                clipView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(positionChanged),
                    name: NSView.boundsDidChangeNotification, object: clipView)
            }
            positionChanged()
        }

        override func layout() {
            super.layout()
            positionChanged()
        }

        @objc private func positionChanged() {
            guard let clipView else { return }
            let frame = convert(bounds, to: clipView).offsetBy(
                dx: -clipView.bounds.minX, dy: -clipView.bounds.minY)
            guard frame != lastObservedFrame else { return }
            lastObservedFrame = frame
            pendingUpdate?.cancel()
            let update = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingUpdate = nil
                self.onChange?(frame)
            }
            pendingUpdate = update
            // Each movement, including momentum scrolling, restarts the quiet period.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: update)
        }

        deinit {
            pendingUpdate?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}
