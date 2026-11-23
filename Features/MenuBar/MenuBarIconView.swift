import AppKit
import SwiftUI

struct MenuBarIconView: View {
    var body: some View {
        Image(nsImage: Self.statusImage)
            .renderingMode(.template)
            .accessibilityLabel("Omdo")
    }

    private static let statusImage: NSImage = {
        // MenuBarExtra uses the image's intrinsic size for the status item.
        let size = NSSize(width: 16, height: 16)
        let artwork = NSImage(named: "OmdoMark")
        let image = NSImage(size: size, flipped: false) { rect in
            artwork?.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }()
}
