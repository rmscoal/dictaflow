import AppKit
import SwiftUI

struct OmdoWindowBackdrop: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.usesGlassWindowBackground) private var usesGlassWindowBackground

    static func makeView() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        Self.makeView()
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.isHidden = reduceTransparency || !usesGlassWindowBackground
    }
}
