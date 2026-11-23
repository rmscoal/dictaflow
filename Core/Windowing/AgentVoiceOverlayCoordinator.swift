import AgentVoice
import AppKit
import Combine
import QuartzCore
import SwiftUI

/// A nonactivating voice control keeps the user's insertion target focused.
/// The recording overlay takes over as soon as dictation interrupts speech.
@MainActor
final class AgentVoiceOverlayCoordinator {
    private let voice: AgentVoiceCoordinator
    private let mouseLocation: () -> NSPoint
    private let record: () -> Void
    private var observation: AnyCancellable?
    private var panel: NSPanel?
    private var hostingView: AgentVoiceHostingView?
    private var hoverTask: Task<Void, Never>?
    private var targetSize = AgentVoiceOverlayLayout.collapsedSize
    /// Collapsed width fitted to the current host name and status text, so
    /// neither ever truncates; never narrower than the default pill.
    private var currentCollapsedSize = AgentVoiceOverlayLayout.collapsedSize
    private(set) var isControlExpanded = false

    init(voice: AgentVoiceCoordinator, mouseLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         record: @escaping () -> Void) {
        self.voice = voice
        self.mouseLocation = mouseLocation
        self.record = record
        observation = voice.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    /// Test seam: whether the floating control is currently shown.
    var isControlVisible: Bool { panel?.isVisible == true }
    var controlFrame: NSRect? { panel?.frame }

    deinit { hoverTask?.cancel() }

    /// A tracking event can come from resizing the panel under a stationary pointer.
    func updateHover() {
        guard isControlVisible else { return }
        let hovered = isPointerOverControl
        guard hovered != isControlExpanded else {
            cancelHover()
            return
        }
        // Identical observations share the same deadline.
        guard hoverTask == nil else { return }
        hoverTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(hovered ? 90 : 280))
            } catch { return }
            guard !Task.isCancelled, let self, self.isControlVisible else { return }
            self.hoverTask = nil
            guard self.isPointerOverControl == hovered else { return }
            self.setExpanded(hovered) { [weak self] in
                // Reconcile once in case the moving edge swallowed a tracking event.
                Task { @MainActor [weak self] in self?.updateHover() }
            }
        }
    }

    private func cancelHover() {
        hoverTask?.cancel()
        hoverTask = nil
    }

    private var isPointerOverControl: Bool {
        guard let panel else { return false }
        // Use the destination size so the animated edges cannot change the result.
        return anchoredFrame(for: targetSize, in: panel.frame).contains(mouseLocation())
    }

    private func anchoredFrame(for size: NSSize, in frame: NSRect) -> NSRect {
        // Keep the lower-right corner fixed, including after the user moves the panel.
        NSRect(x: frame.maxX - size.width, y: frame.minY, width: size.width, height: size.height)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool = true,
                             completion: (@Sendable () -> Void)? = nil) {
        guard let panel else { return }
        if isControlExpanded != expanded {
            isControlExpanded = expanded
            updateContent()
        }
        let size = expanded
            ? AgentVoiceOverlayLayout.expandedSize(isReady: hostingView?.rootView.isReady == true,
                                                  minimumWidth: currentCollapsedSize.width)
            : currentCollapsedSize
        // Speech updates must not restart an in-flight resize toward the same size.
        guard size != targetSize || !animated else { return }
        targetSize = size
        let frame = anchoredFrame(for: size, in: panel.frame)
        guard animated, panel.occlusionState.contains(.visible),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: completion)
    }

    private var readyInteraction: VoiceHistoryRecord? {
        voice.history.first { record in
            record.interaction.stopEligibleRevision != nil &&
            !record.interaction.isSuppressed && !record.interaction.hostClosed &&
            !record.attempts.contains { $0.renditionID == record.interaction.currentRenditionID } &&
            !record.renditions.isEmpty
        }
    }

    private func update() {
        let ready = readyInteraction
        let showReady = voice.admissionPolicy == .manualOnly && ready != nil
        guard voice.isEnabled, !voice.isForegroundBusy, voice.isSpeaking || voice.isGenerating || showReady else {
            cancelHover()
            panel?.orderOut(nil)
            if panel != nil { setExpanded(false, animated: false) }
            return
        }
        if panel == nil {
            let panel = AgentVoicePanel(contentRect: NSRect(origin: .zero, size: AgentVoiceOverlayLayout.collapsedSize),
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.title = "Agent Voice"
            if let frame = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - AgentVoiceOverlayLayout.screenInset,
                                             y: frame.minY + AgentVoiceOverlayLayout.screenInset))
            }
            self.panel = panel
        }
        updateContent()
        // Ready mode has one extra action; resize without resetting the hover state.
        if isControlExpanded { setExpanded(true) }
        else if currentCollapsedSize != targetSize { setExpanded(false, animated: false) }
        panel?.orderFrontRegardless()
    }

    private func updateContent() {
        let ready = readyInteraction
        let readySource = ready.map { "\($0.interaction.session.host) · \($0.interaction.session.sessionID.prefix(8))" }
        let source = voice.activeSource ?? readySource ?? "Agent Voice"
        let status = voice.isSpeaking ? "Speaking" : voice.isGenerating ? "Generating…" : "Response ready"
        let isReady = voice.admissionPolicy == .manualOnly && ready != nil && !voice.isSpeaking && !voice.isGenerating
        let hostDisplayName = AgentVoiceHostBrand.brand(
            forHostName: source.components(separatedBy: " · ").first ?? source).displayName
        currentCollapsedSize = AgentVoiceOverlayLayout.collapsedSize(
            hostName: hostDisplayName, status: isReady ? "Ready" : status)
        let view = AgentVoiceOverlay(
            source: source,
            status: status,
            isReady: isReady,
            isExpanded: isControlExpanded,
            expand: { [weak self] in
                self?.cancelHover()
                self?.setExpanded(true)
            },
            stop: { [weak voice] in
                guard let voice else { return }
                if voice.isSpeaking || voice.isGenerating { voice.stopSpeech() }
                else if let id = ready?.id { voice.dismissReadyInteraction(id) }
            },
            play: { [weak voice] in
                if let id = ready?.interaction.currentRenditionID {
                    Task { await voice?.playRendition(id) }
                }
            },
            record: record
        )
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = AgentVoiceHostingView(rootView: view)
            hostingView.sizingOptions = []
            hostingView.onHover = { [weak self] in self?.updateHover() }
            panel?.contentView = hostingView
            self.hostingView = hostingView
        }
    }
}

private final class AgentVoiceHostingView: NSHostingView<AgentVoiceOverlay> {
    var onHover: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // AppKit keeps this area in sync with the hosting view during a resize.
        guard hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === hoverTrackingArea { onHover?() }
        else { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === hoverTrackingArea { onHover?() }
        else { super.mouseExited(with: event) }
    }
}

private final class AgentVoicePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum AgentVoiceOverlayLayout {
    static let collapsedSize = NSSize(width: 176, height: 44)

    /// Width that fits this host name and status in full: 14 pt padding on
    /// each side, the 24 pt host icon, and the three 8 pt gaps around the
    /// flexible spacer. The pill only ever grows from the default width, so
    /// longer host names widen it instead of truncating either text.
    static func collapsedSize(hostName: String, status: String) -> NSSize {
        let nameWidth = (hostName as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        let statusWidth = (status as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11)]).width
        let width = ceil(28 + 24 + 24 + nameWidth + statusWidth) + 2
        return NSSize(width: max(collapsedSize.width, width), height: collapsedSize.height)
    }

    static func expandedSize(isReady: Bool, minimumWidth: CGFloat) -> NSSize {
        // Long host names can widen the compact pill beyond the default control width.
        NSSize(width: max(isReady ? 360 : 340, minimumWidth), height: 68)
    }

    static let screenInset: CGFloat = 24
    static let cornerRadius: CGFloat = 22
}

private struct AgentVoiceOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: String
    let status: String
    let isReady: Bool
    let isExpanded: Bool
    let expand: () -> Void
    let stop: () -> Void
    let play: () -> Void
    let record: () -> Void

    var body: some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Agent Voice. \(source). \(status)")
    }

    private var statusColor: Color {
        isReady ? AppTheme.ready : AppTheme.secondaryText
    }

    private var hostName: String { source.components(separatedBy: " · ").first ?? source }

    /// Capitalized display name and vendor logo for the speaking host, shared
    /// with setup cards and history so the panel never shows the raw
    /// lowercase `--host` flag ("codex", "claude", "muse").
    private var brand: AgentVoiceHostBrand { AgentVoiceHostBrand.brand(forHostName: hostName) }
    private var displayHostName: String { brand.displayName }

    private func hostIcon(size: CGFloat) -> some View {
        AgentVoiceHostIcon(brand: brand, size: size)
    }

    private var content: some View {
        GeometryReader { geometry in
            ZStack {
                expandedContent
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(isExpanded ? 1 : 0)
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
                Button(action: expand) {
                    HStack(spacing: 8) {
                        hostIcon(size: 24)
                        // The host name never truncates: it is the panel's
                        // identity. The status text yields first instead.
                        Text(displayHostName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        Text(isReady ? "Ready" : status)
                            .font(.system(size: 11))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(EmberButtonStyle(appearance: .plain))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .accessibilityLabel("Show speech controls. \(displayHostName). \(status)")
                .accessibilityIdentifier("agent-voice-overlay-expand")
                .opacity(isExpanded ? 0 : 1)
                .allowsHitTesting(!isExpanded)
                .accessibilityHidden(isExpanded)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .help(source)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16).delay(isExpanded ? 0.1 : 0), value: isExpanded)
        .foregroundStyle(AppTheme.primaryText)
        .omdoFloatingWindowBackground(
            in: RoundedRectangle(cornerRadius: AgentVoiceOverlayLayout.cornerRadius), strongerLightTint: true
        )
    }

    private var expandedContent: some View {
        HStack(spacing: 12) {
            hostIcon(size: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayHostName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(source)

            HStack(spacing: 8) {
                Button(action: stop) {
                    HStack(spacing: 6) {
                        if !isReady {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 7))
                                .accessibilityHidden(true)
                        }
                        Text(isReady ? "Dismiss" : "Stop")
                    }
                }
                .accessibilityIdentifier("agent-voice-overlay-stop")

                if isReady {
                    Button("Play", action: play)
                        .accessibilityIdentifier("agent-voice-overlay-play")
                }
                Button("Dictate", action: record)
                    .buttonStyle(EmberButtonStyle(primary: true))
                    .help("Interrupt speech and start dictation")
                    .accessibilityIdentifier("agent-voice-overlay-dictate")
            }
            .buttonStyle(EmberButtonStyle())
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}
