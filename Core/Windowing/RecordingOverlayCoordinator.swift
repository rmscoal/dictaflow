import Carbon
import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingOverlayCoordinator: RecordingOverlayRouting {
    private let recordingPanelSize = NSSize(width: 220, height: 44)
    private let processingPanelHeight: CGFloat = 44
    private let processingHorizontalPadding: CGFloat = 14
    private let processingMarkWidth: CGFloat = 22
    private let processingContentSpacing: CGFloat = 9
    private let processingTitleWidthAllowance: CGFloat = 8
    private let minimumProcessingPanelWidth: CGFloat = 104
    private let maximumProcessingPanelWidth: CGFloat = 360
    private let sizeAnimationDuration: TimeInterval = 0.22
    private var panel: RecordingOverlayPanel?
    private var viewModel: RecordingOverlayViewModel?
    private var isInputEnabled = false
    private var localEscapeMonitor: Any?
    private var escapeEventTapController: EscapeEventTapController?

    func updateOverlay(
        _ presentation: RecordingOverlayPresentation?,
        cancelAction: @escaping () -> Void
    ) {
        guard let presentation else {
            hideOverlay()
            return
        }

        let panel = makePanelIfNeeded(
            initialPresentation: presentation,
            cancelAction: cancelAction
        )
        let currentPanelSize = panelSize(for: presentation)
        let wasVisible = panel.isVisible
        let wasInputEnabled = isInputEnabled
        let shouldEnableInput = presentation.isCancellable
        let shouldResize = panel.frame.size != currentPanelSize

        panel.onCancel = shouldEnableInput ? cancelAction : nil
        panel.ignoresMouseEvents = !shouldEnableInput
        isInputEnabled = shouldEnableInput

        if shouldEnableInput, !wasInputEnabled {
            startEscapeMonitors()
        } else if !shouldEnableInput, wasInputEnabled {
            stopEscapeMonitors()
        }

        viewModel?.update(
            presentation: presentation,
            cancelAction: cancelAction
        )

        if !wasVisible {
            setFrame(of: panel, for: currentPanelSize, animated: false)
        } else if shouldResize {
            setFrame(of: panel, for: currentPanelSize, animated: true)
        }

        guard !wasVisible else {
            if shouldEnableInput, !wasInputEnabled {
                panel.makeKey()
            } else if !shouldEnableInput, wasInputEnabled {
                panel.resignKey()
            }
            return
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if shouldEnableInput {
            panel.makeKey()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    private func hideOverlay() {
        guard let panel else {
            return
        }

        panel.onCancel = nil
        panel.ignoresMouseEvents = true
        isInputEnabled = false
        stopEscapeMonitors()
        panel.resignKey()
        viewModel?.clearCancelAction()

        guard panel.isVisible else {
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

    private func makePanelIfNeeded(
        initialPresentation: RecordingOverlayPresentation,
        cancelAction: @escaping () -> Void
    ) -> RecordingOverlayPanel {
        if let panel {
            return panel
        }

        let initialPanelSize = panelSize(for: initialPresentation)
        let panel = RecordingOverlayPanel(
            contentRect: NSRect(origin: .zero, size: initialPanelSize),
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

        let viewModel = RecordingOverlayViewModel(
            presentation: initialPresentation,
            cancelAction: cancelAction
        )
        panel.contentView = TransparentHostingView(
            rootView: RecordingOverlayView(viewModel: viewModel)
        )

        self.viewModel = viewModel
        self.panel = panel
        return panel
    }

    private func startEscapeMonitors() {
        guard localEscapeMonitor == nil, escapeEventTapController == nil else {
            return
        }

        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard isBareEscapeKeyEvent(event) else {
                return event
            }

            Task { @MainActor [weak self] in
                self?.panel?.onCancel?()
            }
            return nil
        }

        let eventTapController = EscapeEventTapController()
        let didStartEventTap = eventTapController.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.panel?.onCancel?()
            }
        }
        if didStartEventTap {
            escapeEventTapController = eventTapController
        }
    }

    private func stopEscapeMonitors() {
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }

        if let escapeEventTapController {
            escapeEventTapController.stop()
            self.escapeEventTapController = nil
        }
    }

    private func panelSize(for presentation: RecordingOverlayPresentation) -> NSSize {
        switch presentation.phase {
        case .recording:
            return recordingPanelSize
        case .requestingPermission,
             .downloadingModel,
             .transcribing,
             .refining,
             .requestingAccessibilityPermission,
             .inserting:
            let titleWidth = ceil(
                (presentation.title as NSString).size(
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
                    ]
                ).width
            )
            let contentWidth = processingHorizontalPadding * 2
                + processingMarkWidth
                + processingContentSpacing
                + titleWidth
                + processingTitleWidthAllowance
            let panelWidth = min(
                max(contentWidth, minimumProcessingPanelWidth),
                maximumProcessingPanelWidth
            )
            return NSSize(width: panelWidth, height: processingPanelHeight)
        }
    }

    private func setFrame(of panel: NSPanel, for size: NSSize, animated: Bool) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let bottomInset: CGFloat = 28
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + bottomInset
        )
        let frame = NSRect(origin: origin, size: size)

        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = sizeAnimationDuration
            panel.animator().setFrame(frame, display: true)
        }
    }
}

private final class RecordingOverlayPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func sendEvent(_ event: NSEvent) {
        if isBareEscapeKeyEvent(event), let onCancel {
            onCancel()
            return
        }

        super.sendEvent(event)
    }
}

private final class EscapeEventTapController: @unchecked Sendable {
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var eventTapSource: CFRunLoopSource?
    nonisolated(unsafe) private var onEscape: (() -> Void)?

    nonisolated func start(onEscape: @escaping () -> Void) -> Bool {
        guard eventTap == nil else {
            return true
        }

        self.onEscape = onEscape
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, eventType, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let controller = Unmanaged<EscapeEventTapController>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                return controller.handle(eventType: eventType, event: event)
            },
            userInfo: userInfo
        ) else {
            self.onEscape = nil
            return false
        }

        self.eventTap = eventTap

        guard let eventTapSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
            self.onEscape = nil
            return false
        }

        self.eventTapSource = eventTapSource
        CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    nonisolated func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            self.eventTapSource = nil
        }

        self.eventTap = nil
        self.onEscape = nil
    }

    nonisolated private func handle(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout, let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }

        guard eventType == .keyDown, isBareEscapeKeyEvent(event) else {
            return Unmanaged.passUnretained(event)
        }

        onEscape?()
        return nil
    }
}

private func isBareEscapeKeyEvent(_ event: NSEvent) -> Bool {
    event.type == .keyDown
        && event.keyCode == UInt16(kVK_Escape)
        && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
}

private nonisolated func isBareEscapeKeyEvent(_ event: CGEvent) -> Bool {
    let disallowedFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    return event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape)
        && event.flags.intersection(disallowedFlags).isEmpty
}

@MainActor
private final class RecordingOverlayViewModel: ObservableObject {
    @Published private(set) var presentation: RecordingOverlayPresentation
    private var cancelAction: (() -> Void)?

    init(
        presentation: RecordingOverlayPresentation,
        cancelAction: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.cancelAction = cancelAction
    }

    func update(
        presentation: RecordingOverlayPresentation,
        cancelAction: @escaping () -> Void
    ) {
        if self.presentation != presentation {
            self.presentation = presentation
        }
        self.cancelAction = cancelAction
    }

    func cancel() {
        cancelAction?()
    }

    func clearCancelAction() {
        cancelAction = nil
    }
}

private struct RecordingOverlayView: View {
    @ObservedObject var viewModel: RecordingOverlayViewModel
    @State private var isCancelButtonHovered = false

    private var presentation: RecordingOverlayPresentation {
        viewModel.presentation
    }

    var body: some View {
        Group {
            if presentation.isCancellable {
                recordingContent
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
            } else {
                processingContent
                    .padding(.horizontal, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OverlayTheme.panelFill, in: Capsule(style: .continuous))
    }

    private var recordingContent: some View {
        HStack(spacing: 10) {
            recordingText
                .fixedSize(horizontal: true, vertical: false)

            OverlayWaveformView(audioLevel: presentation.audioLevel)
                .frame(minWidth: 74, maxWidth: .infinity)
                .frame(height: 22)

            cancelButton
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingText: some View {
        Text(presentation.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(OverlayTheme.primaryText)
            .lineLimit(1)
    }

    private var processingContent: some View {
        HStack(spacing: 9) {
            processingMark
                .frame(width: 22, height: 22)

            Text(presentation.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OverlayTheme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: -1)
        }
    }

    @ViewBuilder
    private var processingMark: some View {
        switch presentation.phase {
        case .refining:
            ZStack {
                Circle()
                    .fill(OverlayTheme.controlFill)

                Text("✦")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OverlayTheme.primaryText)
            }
        default:
            OverlayLoadingView()
        }
    }

    private var cancelButton: some View {
        Button(role: .cancel, action: viewModel.cancel) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OverlayTheme.primaryText)
                .frame(width: 26, height: 26)
                .background(
                    isCancelButtonHovered
                        ? OverlayTheme.controlHoverFill
                        : OverlayTheme.controlFill,
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .strokeBorder(OverlayTheme.panelBorder, lineWidth: 0.75)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            isCancelButtonHovered = isHovering
        }
        .animation(.easeOut(duration: 0.12), value: isCancelButtonHovered)
        .help("Cancel recording")
        .accessibilityLabel("Cancel recording")
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
    private static let dotOpacities = [0.76, 0.66, 0.56, 0.46, 0.36, 0.26]

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
        let radius: CGFloat = 8
        let rotation = time * Double.pi * 2 / 1.45

        for index in 0..<dotCount {
            let angle = rotation
                + Double(index) / Double(dotCount) * Double.pi * 2
                - Double.pi / 2
            let x = center.x + CGFloat(cos(angle)) * radius
            let y = center.y + CGFloat(sin(angle)) * radius
            let dotRadius: CGFloat = 2
            let rect = CGRect(
                x: x - dotRadius,
                y: y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity(Self.dotOpacities[index]))
            )
        }
    }
}

private enum OverlayTheme {
    static let panelFill = Color(red: 0.039, green: 0.039, blue: 0.039).opacity(0.96)
    static let panelBorder = Color.white.opacity(0.08)
    static let controlFill = Color.white.opacity(0.055)
    static let controlHoverFill = Color.white.opacity(0.10)
    static let primaryText = Color.white.opacity(0.92)
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    deinit {
        // Work around swiftlang/swift#87736 in Swift 6.3.x.
    }

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
