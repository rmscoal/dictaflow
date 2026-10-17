import AppKit
import SwiftUI

struct MenuBarIconView: View {
    var body: some View {
        Image(nsImage: Self.templateImage)
            .renderingMode(.template)
            .accessibilityLabel("DictaFlow")
    }

    private static let templateImage: NSImage = {
        let imageSize = NSSize(width: 18, height: 18)
        let barWidth: CGFloat = 2
        let barSpacing: CGFloat = 1.5
        let barHeights: [CGFloat] = [6, 10, 15, 10, 6]
        let markWidth = CGFloat(barHeights.count) * barWidth
            + CGFloat(barHeights.count - 1) * barSpacing
        let leadingInset = (imageSize.width - markWidth) / 2

        let image = NSImage(size: imageSize, flipped: false) { _ in
            NSColor.black.setFill()

            for (index, height) in barHeights.enumerated() {
                let x = leadingInset + CGFloat(index) * (barWidth + barSpacing)
                let y = (imageSize.height - height) / 2
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                NSBezierPath(
                    roundedRect: barRect,
                    xRadius: barWidth / 2,
                    yRadius: barWidth / 2
                ).fill()
            }

            return true
        }
        image.isTemplate = true
        return image
    }()
}

