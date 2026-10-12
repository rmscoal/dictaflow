import SwiftUI

struct WhisperModelsView: View {
    @ObservedObject var appState: DictaFlowAppState
    let downloadModel: (WhisperModelDescriptor) -> Void
    let downloadEncoder: (WhisperModelDescriptor) -> Void
    let downloadModelWithEncoder: (WhisperModelDescriptor) -> Void
    let removeModel: (WhisperModelDescriptor) -> Void

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

            HStack(spacing: 5) {
                Image("provider-openai").resizable().scaledToFit().padding(3)
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                Text("OpenAI")
                    .font(.system(size: 11, weight: .medium)).fixedSize()
            }
                .padding(.horizontal, 9).padding(.vertical, 8)
                .foregroundStyle(AppTheme.accent)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.accent))
                .padding(1).fixedSize(horizontal: true, vertical: false)
                .padding(.top, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Speech model provider: OpenAI")
                .accessibilityAddTraits(.isSelected)

            VStack(spacing: 8) {
                ForEach(WhisperModelDescriptor.allCases, id: \.self) { model in
                    modelCard(model)
                }
            }
        }
    }

    private func modelCard(_ model: WhisperModelDescriptor) -> some View {
        let prepared = appState.isWhisperModelPrepared(model)
        let active = prepared && model == appState.whisperConfiguration.model
        let downloadingModel = appState.isDownloadingWhisperModel(model)
        let downloadingEncoder = appState.isDownloadingWhisperEncoder(model)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SpeechProviderIcon()
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName).font(.system(size: 14, weight: .semibold))
                    Text("Whisper · \(model.approximateDiskSizeDescription)")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                if downloadingModel || downloadingEncoder {
                    Button("Cancel") {
                        if downloadingModel { appState.cancelWhisperModelDownload(model) }
                        if downloadingEncoder { appState.cancelWhisperEncoderDownload(model) }
                    }.controlSize(.small)
                } else if active {
                    HStack(spacing: 12) {
                        Text("Active").font(.caption).foregroundStyle(AppTheme.accent)
                        modelMenu(model, prepared: true)
                            .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.border))
                    }
                    .disabled(appState.whisperSettingsLocked || appState.isDeletingModel)
                } else {
                    HStack(spacing: 0) {
                        Button(prepared ? "Use model" : "Download") {
                            if prepared { appState.updateWhisperModel(model) } else { downloadModel(model) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 11)
                        .frame(height: 29)

                        Rectangle()
                            .fill(prepared ? AppTheme.border : Color.white.opacity(0.25))
                            .frame(width: 1, height: 29)
                        modelMenu(model, prepared: prepared)
                    }
                    .foregroundStyle(prepared ? AppTheme.primaryText : Color.white)
                    .background(prepared ? AppTheme.controlFill : AppTheme.accent, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(prepared ? AppTheme.border : Color.clear))
                    .disabled(appState.whisperSettingsLocked || appState.isDeletingModel)
                }
            }
            if downloadingModel {
                downloadProgress(
                    appState.whisperDownloadProgress(for: model),
                    status: "Downloading model · \(appState.whisperDownloadStatusText(for: model))"
                )
            }
            if downloadingEncoder {
                downloadProgress(
                    appState.whisperEncoderDownloadProgress(for: model),
                    status: "Downloading encoder · \(appState.whisperEncoderDownloadStatusText(for: model))"
                )
            }
            if let error = appState.whisperDownloadError(for: model) {
                Text(error).font(.caption).foregroundStyle(AppTheme.warning).textSelection(.enabled)
            }
            if let error = appState.whisperEncoderDownloadError(for: model) {
                Text(error).font(.caption).foregroundStyle(AppTheme.warning).textSelection(.enabled)
            }
        }
        .padding(15)
        .background(active ? AppTheme.accent.opacity(0.07) : AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? AppTheme.accent.opacity(0.5) : AppTheme.border))
    }

    private func modelMenu(_ model: WhisperModelDescriptor, prepared: Bool) -> some View {
        Menu {
            if prepared {
                if appState.isWhisperEncoderDownloaded(model) {
                    Toggle("Use Encoder", isOn: Binding(
                        get: { appState.isWhisperEncoderEnabled(model) },
                        set: { appState.setWhisperEncoderEnabled($0, for: model) }
                    ))
                } else {
                    Button("Download Encoder") { downloadEncoder(model) }
                }
                Divider()
                Button(appState.isWhisperEncoderDownloaded(model) ? "Remove Model and Encoder…" : "Remove Model…", role: .destructive) {
                    removeModel(model)
                }
                .disabled(!appState.canDeleteWhisperModel(model))
                if model == appState.whisperConfiguration.model {
                    Text("Select another model to remove this one.")
                } else if !appState.canDeleteWhisperModel(model) {
                    Text("Keep at least one downloaded model.")
                }
            } else {
                Button("Download with Encoder") { downloadModelWithEncoder(model) }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .frame(width: 30, height: 29)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(model.displayName)")
    }

    private func downloadProgress(_ progress: Double?, status: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status).font(.caption).foregroundStyle(AppTheme.secondaryText)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(AppTheme.accent)
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
