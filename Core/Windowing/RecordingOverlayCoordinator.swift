import AppKit
import SwiftUI

@MainActor
final class RecordingOverlayCoordinator: RecordingOverlayRouting {
    private let panelSize = NSSize(width: 286, height: 52)
    private var panel: NSPanel?

    func updateOverlay(_ presentation: RecordingOverlayPresentation?) {
        guard let presentation else {
            hideOverlay()
            return
        }

        let panel = makePanelIfNeeded()
        if let hostingView = panel.contentView as? TransparentHostingView<RecordingOverlayView> {
            hostingView.rootView = RecordingOverlayView(presentation: presentation)
        } else {
            panel.contentView = TransparentHostingView(
                rootView: RecordingOverlayView(presentation: presentation)
            )
        }
        panel.setContentSize(panelSize)
        position(panel)

        guard !panel.isVisible else {
            return
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    private func hideOverlay() {
        guard let panel, panel.isVisible else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.title = "Recording Status"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let bottomInset: CGFloat = 28
        let origin = NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.minY + bottomInset
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }
}

private struct RecordingOverlayView: View {
    let presentation: RecordingOverlayPresentation

    var body: some View {
        HStack(spacing: 10) {
            statusIcon

            activityIndicator
            .frame(width: 74, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OverlayTheme.primaryText)

                Text(presentation.detail)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(OverlayTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .frame(width: 286, height: 52)
        .background(OverlayTheme.panelFill, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(OverlayTheme.panelBorder, lineWidth: 0.75)
        }
    }

    @ViewBuilder
    private var activityIndicator: some View {
        if presentation.showsLiveWaveform {
            OverlayWaveformView(audioLevel: presentation.audioLevel)
        } else {
            OverlayLoadingView()
        }
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(iconFill)

            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconForeground)
        }
        .frame(width: 28, height: 28)
    }

    private var iconName: String {
        switch presentation.phase {
        case .recording:
            return "mic.fill"
        case .requestingPermission:
            return "lock.shield.fill"
        case .stopping:
            return "stop.fill"
        case .preparingModel, .downloadingModel, .transcribing:
            return "waveform.badge.magnifyingglass"
        case .refining:
            return "sparkles"
        case .requestingAccessibilityPermission:
            return "accessibility"
        case .inserting:
            return "text.cursor"
        }
    }

    private var iconFill: Color {
        OverlayTheme.controlFill
    }

    private var iconForeground: Color {
        OverlayTheme.primaryText
    }
}

private struct OverlayWaveformView: View {
    let audioLevel: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                drawWaveform(in: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func drawWaveform(in context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let barCount = 18
        let spacing: CGFloat = 3
        let barWidth = (size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount)
        let clampedLevel = min(max(audioLevel, 0), 1)
        let animationPhase = time * 8

        for index in 0..<barCount {
            let x = CGFloat(index) * (barWidth + spacing)
            let movement = abs(sin(animationPhase + Double(index) * 0.68))
            let level = max(0.08, clampedLevel)
            let heightScale = 0.18 + level * (0.24 + movement * 0.72)
            let barHeight = max(4, size.height * min(heightScale, 1))
            let rect = CGRect(
                x: x,
                y: (size.height - barHeight) / 2,
                width: barWidth,
                height: barHeight
            )
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            let opacity = 0.34 + movement * 0.5
            context.fill(path, with: .color(OverlayTheme.primaryText.opacity(opacity)))
        }
    }
}

private struct OverlayLoadingView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                drawLoadingMark(in: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func drawLoadingMark(in context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let dotCount = 6
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.32
        let activePhase = time * 3.4

        for index in 0..<dotCount {
            let angle = Double(index) / Double(dotCount) * Double.pi * 2
            let x = center.x + CGFloat(cos(angle)) * radius
            let y = center.y + CGFloat(sin(angle)) * radius
            let pulse = (sin(activePhase - Double(index) * 0.72) + 1) / 2
            let dotRadius = 1.6 + CGFloat(pulse) * 0.85
            let rect = CGRect(
                x: x - dotRadius,
                y: y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(OverlayTheme.primaryText.opacity(0.24 + pulse * 0.54))
            )
        }
    }
}

private enum OverlayTheme {
    static let panelFill = Color(red: 0.039, green: 0.039, blue: 0.039).opacity(0.96)
    static let panelBorder = Color.white.opacity(0.08)
    static let controlFill = Color.white.opacity(0.055)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.45)
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        get {
            false
        }
        set {}
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        configureTransparency()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureTransparency()
    }

    private func configureTransparency() {
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        window?.backgroundColor = .clear
        window?.isOpaque = false
    }
}
