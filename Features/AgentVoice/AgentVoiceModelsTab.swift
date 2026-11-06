import SwiftUI

/// Second Agent Voice tab. The Liquid speech model is the only voice
/// backend, shared with dictation recognition.
struct AgentVoiceModelsTab: View {
    @ObservedObject var voice: AgentVoiceCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmberModuleHeading(title: "Models")
            EmberSectionHeading(title: "Speech model")
            SelectedModelCard(
                name: "Liquid LFM3-Audio-2B",
                providerAsset: "provider-liquid",
                status: voice.isModelReady ? "Ready" : voice.isDownloading ? "Downloading…" : "Download needed",
                size: "1.4 GB",
                hasError: voice.activeError?.scope == .models,
                actionTitle: voice.isModelReady ? "Ready" : voice.isDownloading ? "Downloading…" : "Download…",
                disabled: voice.isModelReady || voice.isDownloading
            ) {
                voice.downloadModel()
            }
            .accessibilityLabel("Liquid speech model, \(voice.isModelReady ? "ready" : voice.isDownloading ? "downloading" : "download needed")")
            .padding(.bottom, 14)
            if let error = voice.activeError, error.scope == .models {
                EmberErrorBanner(title: "Liquid download failed", message: error.message)
                    .padding(.bottom, 26)
                    .accessibilityLabel("Liquid download failed. \(error.message)")
            }
        }
    }
}
