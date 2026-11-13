import SwiftUI

/// Speech model section in General. Liquid is shared with dictation.
struct AgentVoiceModelsTab: View {
    @ObservedObject var voice: AgentVoiceCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmberSectionHeading(title: "Speech model")
            EmberPanel {
                EmberRow(title: "Liquid LFM3-Audio-2B", detail: "1.4 GB · Local speech model", asset: "provider-liquid") {
                    if voice.isModelReady {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.modelActive)
                    } else if voice.isDownloading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Downloading…").font(.system(size: 12))
                        }
                        .accessibilityLabel("Downloading speech model")
                    } else {
                        Button("Download…") { voice.downloadModel() }
                            .buttonStyle(EmberButtonStyle(primary: true))
                    }
                }
            }
            if let error = voice.activeError, error.scope == .models {
                EmberErrorBanner(title: "Liquid download failed", message: error.message)
                    .padding(.bottom, 26)
                    .accessibilityLabel("Liquid download failed. \(error.message)")
            }
        }
    }
}
