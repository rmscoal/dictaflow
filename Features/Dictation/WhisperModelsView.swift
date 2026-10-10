import SwiftUI

struct WhisperModelsView: View {
    @ObservedObject var appState: DictaFlowAppState
    let downloadModel: (WhisperModelDescriptor) -> Void
    let downloadEncoder: (WhisperModelDescriptor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SpeechProviderIcon()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected model").font(.caption).foregroundStyle(AppTheme.secondaryText)
                    Text(appState.whisperConfiguration.model.displayName).fontWeight(.semibold)
                }
                Spacer()
                Text(appState.isWhisperModelPrepared(appState.whisperConfiguration.model) ? "Ready locally" : "Download needed")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            .padding(16).background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.border))

            HStack {
                HStack(spacing: 5) {
                    SpeechProviderIcon(size: 20)
                    Text("OpenAI").font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 9).padding(.vertical, 8)
                .foregroundStyle(AppTheme.accent)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.accent))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isSelected)
                Spacer()
            }.accessibilityLabel("Speech model provider: OpenAI")

            VStack(spacing: 8) {
                ForEach(WhisperModelDescriptor.allCases, id: \.self) { model in
                    modelCard(model)
                }
            }
        }
    }

    private func modelCard(_ model: WhisperModelDescriptor) -> some View {
        let prepared = appState.isWhisperModelPrepared(model)
        let active = model == appState.whisperConfiguration.model
        let downloading = appState.isDownloadingWhisperModel(model)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SpeechProviderIcon()
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName).font(.system(size: 14, weight: .semibold))
                    Text("Whisper · \(model.approximateDiskSizeDescription)")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                if downloading {
                    Button("Cancel") { appState.cancelWhisperModelDownload(model) }.controlSize(.small)
                } else if prepared && active {
                    Text("Active").font(.caption).foregroundStyle(AppTheme.accent)
                } else {
                    Button(prepared ? "Use model" : "Download") {
                        if prepared { appState.updateWhisperModel(model) } else { downloadModel(model) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(AppTheme.accent)
                    .disabled(appState.whisperSettingsLocked || appState.isDeletingModel)
                }
            }
            if downloading {
                ProgressView(value: appState.whisperDownloadProgress(for: model) ?? 0)
                Text(appState.whisperDownloadStatusText(for: model)).font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            if let error = appState.whisperDownloadError(for: model) {
                Text(error).font(.caption).foregroundStyle(AppTheme.warning).textSelection(.enabled)
            }
            Divider().overlay(AppTheme.border)
            DisclosureGroup {
                encoderControls(model, prepared: prepared)
                    .padding(.top, 8)
            } label: {
                HStack {
                    Label("Neural Engine", systemImage: "bolt")
                    Spacer()
                    Text(appState.isWhisperEncoderEnabled(model) ? "On" : "Optional")
                        .foregroundStyle(AppTheme.secondaryText)
                }.font(.caption)
            }
        }
        .padding(15)
        .background(active ? AppTheme.accent.opacity(0.07) : AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? AppTheme.accent.opacity(0.5) : AppTheme.border))
    }

    private func encoderControls(_ model: WhisperModelDescriptor, prepared: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.isDownloadingWhisperEncoder(model) {
                HStack {
                    Text(appState.whisperEncoderDownloadStatusText(for: model)).font(.caption)
                    Spacer()
                    Button("Cancel") { appState.cancelWhisperEncoderDownload(model) }.controlSize(.small)
                }
                ProgressView(value: appState.whisperEncoderDownloadProgress(for: model) ?? 0)
            } else if appState.isWhisperEncoderDownloaded(model) {
                HStack {
                    Toggle("Use Neural Engine", isOn: Binding(
                        get: { appState.isWhisperEncoderEnabled(model) },
                        set: { appState.setWhisperEncoderEnabled($0, for: model) }))
                        .toggleStyle(.switch).controlSize(.small)
                    Spacer()
                    Menu {
                        Button("Remove encoder", role: .destructive) { appState.removeWhisperEncoder(model) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Encoder actions for \(model.displayName)")
                }.disabled(appState.whisperSettingsLocked || appState.isDeletingModel)
                Text("Downloaded · \(model.encoderApproximateSizeDescription)").font(.caption).foregroundStyle(AppTheme.secondaryText)
            } else {
                HStack {
                    Text(model.encoderApproximateSizeDescription).font(.caption).foregroundStyle(AppTheme.secondaryText)
                    Spacer()
                    Button("Download encoder") { downloadEncoder(model) }
                        .controlSize(.small)
                        .disabled(!prepared || appState.whisperSettingsLocked || appState.isDeletingModel)
                }
                if !prepared {
                    Text("Download the speech model first.").font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
            }
            if let error = appState.whisperEncoderDownloadError(for: model) {
                Text(error).font(.caption).foregroundStyle(AppTheme.warning).textSelection(.enabled)
            }
        }
    }
}

private struct SpeechProviderIcon: View {
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: "waveform").resizable().scaledToFit().padding(5)
            .foregroundStyle(Color.black)
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}
