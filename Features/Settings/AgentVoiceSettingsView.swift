import AgentVoice
import SwiftUI

struct AgentVoiceSettingsView: View {
    @ObservedObject var voice: AgentVoiceCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmberModuleHeading(title: "Agent Voice · Preview")
            Toggle("Enable local MCP connection", isOn: Binding(get: { voice.isEnabled }, set: { voice.setEnabled($0) }))
            Text(voice.status).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            HStack {
                Button(voice.isModelReady ? "Liquid audio ready" : voice.isDownloading ? "Downloading…" : "Download Liquid audio (1.4 GB)") { voice.downloadModel() }
                    .disabled(voice.isModelReady || voice.isDownloading)
                if voice.isSpeaking { Button("Stop speech") { voice.stopSpeech() } }
            }
            .buttonStyle(EmberButtonStyle())
            if voice.isEnabled {
                Text("MCP command (use a stable host session ID)").font(.system(size: 12, weight: .medium))
                Text(voice.connectionCommand).textSelection(.enabled).font(.system(size: 10, design: .monospaced))
                Text("Automatic playback awaits a verified host completion signal. Play a prepared rendition explicitly below. Tool calls stay visible in the host's normal activity.")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                ForEach(voice.drafts.prefix(5)) { draft in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.text).lineLimit(3)
                            Text(draft.state.rawValue).foregroundStyle(AppTheme.secondaryText)
                        }
                        Spacer()
                        Button("Play") { voice.speak(draft) }
                            .disabled(!voice.isModelReady || ![.prepared, .awaitingCompletion, .completed, .failed, .cancelled].contains(draft.state))
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .padding(.top, 24)
    }
}
