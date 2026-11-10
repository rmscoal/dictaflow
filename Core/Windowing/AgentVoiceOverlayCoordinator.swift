import AgentVoice
import AppKit
import Combine
import SwiftUI

/// A nonactivating voice control keeps the user's insertion target focused.
/// The recording overlay takes over as soon as dictation interrupts speech.
@MainActor
final class AgentVoiceOverlayCoordinator {
    private let voice: AgentVoiceCoordinator
    private let record: () -> Void
    private var observation: AnyCancellable?
    private var panel: NSPanel?

    init(voice: AgentVoiceCoordinator, record: @escaping () -> Void) {
        self.voice = voice
        self.record = record
        observation = voice.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    /// Test seam: whether the floating control is currently shown.
    var isControlVisible: Bool { panel?.isVisible == true }

    private func update() {
        let ready = voice.history.first { record in
            record.interaction.stopEligibleRevision != nil &&
            !record.interaction.isSuppressed && !record.interaction.hostClosed &&
            !record.attempts.contains { $0.renditionID == record.interaction.currentRenditionID } &&
            !record.renditions.isEmpty
        }
        let showReady = voice.admissionPolicy == .manualOnly && ready != nil
        guard voice.isEnabled, !voice.isForegroundBusy, voice.isSpeaking || voice.isGenerating || showReady else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            let panel = AgentVoicePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 94),
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
            panel.title = "Agent Voice"
            if let frame = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 360, y: frame.minY + 24))
            }
            self.panel = panel
        }
        let readySource = ready.map { "\($0.interaction.session.host) · \($0.interaction.session.sessionID.prefix(8))" }
        panel?.contentView = NSHostingView(rootView: AgentVoiceOverlay(
            source: voice.activeSource ?? readySource ?? "Agent Voice",
            status: voice.isSpeaking ? "Speaking" : voice.isGenerating ? "Generating speech…" : "Response ready",
            isReady: showReady && !voice.isSpeaking && !voice.isGenerating,
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
        ))
        panel?.orderFrontRegardless()
    }
}

private final class AgentVoicePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct AgentVoiceOverlay: View {
    let source: String
    let status: String
    let isReady: Bool
    let stop: () -> Void
    let play: () -> Void
    let record: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform")
                Text(source).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button(isReady ? "Dismiss" : "Stop", action: stop)
                    .accessibilityIdentifier("agent-voice-overlay-stop")
                Spacer()
                if isReady { Button("Play", action: play) }
                Button(action: record) { Label("Dictate", systemImage: "mic.fill") }
                    .accessibilityIdentifier("agent-voice-overlay-dictate")
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(width: 340, height: 94)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.12)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent Voice. \(source). \(status)")
    }
}
