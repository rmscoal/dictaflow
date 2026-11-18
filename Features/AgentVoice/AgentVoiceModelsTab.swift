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
}
