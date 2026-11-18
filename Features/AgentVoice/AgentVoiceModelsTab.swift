import AgentVoice
import SwiftUI

/// Speech model section in General. Liquid is shared with dictation.
struct AgentVoiceModelsTab: View {
    @ObservedObject var voice: AgentVoiceCoordinator
    @State private var confirmsCancellation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmberSectionHeading(title: "Speech model")
            EmberPanel {
                EmberRow(title: "Liquid LFM3-Audio-2B", detail: "1.4 GB · Local speech model", asset: "provider-liquid") {
                    if voice.isDownloading {
                        Button("Cancel") { confirmsCancellation = true }
                            .buttonStyle(EmberButtonStyle())
                    } else if voice.isModelReady {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.modelActive)
                    } else {
                        Button("Download…") { voice.downloadModel() }
                            .buttonStyle(EmberButtonStyle(primary: true))
                    }
                }
                if let download = voice.modelDownloadProgress {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(download.statusText).foregroundStyle(AppTheme.secondaryText)
                            Spacer(minLength: 8)
                            if let progress = download.progress {
                                Text("\(Int((progress * 100).rounded()))%")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                        .font(.system(size: 11))
                        EmberDownloadProgress(value: download.progress)
                            .accessibilityLabel("Speech model download progress")
                    }
                    .padding(.horizontal, 20).padding(.bottom, 18)
                }
                EmberDivider()
                voicePicker
                EmberDivider()
                speedSlider
                EmberDivider()
                previewRow
            }
            if let error = voice.activeError, error.scope == .models {
                EmberErrorBanner(title: "Liquid download failed", message: error.message)
                    .padding(.bottom, 26)
                    .accessibilityLabel("Liquid download failed. \(error.message)")
            }
        }
        .alert("Cancel download?", isPresented: $confirmsCancellation) {
            Button("Keep downloading", role: .cancel) {}
            Button("Cancel download", role: .destructive) { voice.cancelModelDownload() }
        } message: {
            Text("The partial file will be removed. Any verified model files will be kept for retry.")
        }
    }

    private var voicePicker: some View {
        EmberRow(title: "Voice") {
            Picker("Voice", selection: Binding(get: { voice.speechVoice }, set: { voice.setSpeechVoice($0) })) {
                Text("Female").tag(LiquidVoice.female)
                Text("Male").tag(LiquidVoice.male)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 144)
            .accessibilityLabel("Voice")
            .accessibilityIdentifier("agent-voice-preset")
        }
    }

    private var speedSlider: some View {
        EmberRow(title: "Playback speed") {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 3) {
                    Slider(value: Binding(get: { voice.playbackRate }, set: { voice.setPlaybackRate($0) }),
                           in: AgentVoiceCoordinator.playbackRateRange, step: 0.05) {
                        Text("Playback speed")
                    }
                    .labelsHidden()
                    .tint(AppTheme.accent)
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(rateLabel)
                    .accessibilityIdentifier("agent-voice-playback-speed")
                    HStack {
                        Text("0.75×")
                        Spacer()
                        Text("1.5×")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityHidden(true)
                }
                .frame(width: 170)
                Text(rateLabel)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 43, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    private var rateLabel: String {
        voice.playbackRate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private var previewRow: some View {
        HStack(spacing: 12) {
            Button(isPreviewActive ? "Stop preview" : "Preview voice", systemImage: isPreviewActive ? "stop.fill" : "play.fill") {
                if isPreviewActive { voice.stopVoicePreview() }
                else { voice.previewVoice() }
            }
            .buttonStyle(EmberButtonStyle())
            .disabled(voice.previewState == .stopping || (!isPreviewActive && !voice.canPreviewVoice))
            .accessibilityIdentifier("agent-voice-preview")

            Text(previewStatus)
                .font(.system(size: 12))
                .foregroundStyle(previewFailed ? AppTheme.errorText : AppTheme.secondaryText)
                .accessibilityIdentifier("agent-voice-preview-status")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var isPreviewActive: Bool {
        switch voice.previewState {
        case .generating, .playing, .stopping: true
        case .idle, .failed: false
        }
    }

    private var previewFailed: Bool {
        if case .failed = voice.previewState { return true }
        return false
    }

    private var previewStatus: String {
        switch voice.previewState {
        case .generating: return "Generating preview…"
        case .playing: return "Playing preview…"
        case .stopping: return "Stopping preview…"
        case .failed(let message): return message
        case .idle:
            if !voice.isEnabled { return "Enable Agent Voice to play a sample." }
            if !voice.isModelReady { return "Download the speech model to play a sample." }
            if !voice.canPreviewVoice { return "Preview is available when dictation and agent speech are idle." }
            return "Applies to automatic replies and History replay."
        }
    }
}
