import SwiftUI

/// Tracks the columns in the native clip view, including scroll-only changes.
struct ScrollViewportPositionReader: NSViewRepresentable {
    var onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> PositionView { PositionView() }

    func updateNSView(_ view: PositionView, context: Context) {
        view.onChange = onChange
    }

    final class PositionView: NSView {
        var onChange: ((CGRect) -> Void)?
        private weak var clipView: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            clipView = enclosingScrollView?.contentView
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
            // Deliver outside AppKit layout to avoid mutating SwiftUI during updates.
            DispatchQueue.main.async { [weak self] in self?.onChange?(frame) }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
