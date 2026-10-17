import SwiftUI

struct WhisperModelsView: View {
    @ObservedObject var appState: DictaFlowAppState
    let downloadModel: (WhisperModelDescriptor) -> Void
    let downloadEncoder: (WhisperModelDescriptor) -> Void
    let removeModel: (WhisperModelDescriptor) -> Void
    @State private var encoderPendingRemoval: WhisperModelDescriptor?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 7) {
                EmberProviderIcon(asset: "provider-openai", size: 24)
                Text("OpenAI").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(AppTheme.selectedFill, in: Capsule())
            .overlay { Capsule().stroke(AppTheme.accent, lineWidth: 1) }
            .accessibilityElement(children: .combine)
            VStack(spacing: 0) {
                ForEach(WhisperModelDescriptor.allCases, id: \.self) { model in
                    modelRow(model).id(model.modelIdentifier)
                    if model != WhisperModelDescriptor.allCases.last { EmberDivider() }
                }
            }
            DisclosureGroup {
                encoderControls.padding(.top, 12)
            } label: {
                HStack {
                    Text("Neural Engine acceleration")
                    Spacer()
                    Text("Optional").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                }
            }
            .disclosureGroupStyle(EmberDisclosureGroupStyle())
            .font(.system(size: 12))
        }
        .alert("Remove the encoder?", isPresented: Binding(get: { encoderPendingRemoval != nil }, set: { if !$0 { encoderPendingRemoval = nil } })) {
            Button("Cancel", role: .cancel) { encoderPendingRemoval = nil }
            Button("Remove encoder", role: .destructive) {
                if let model = encoderPendingRemoval { appState.removeWhisperEncoder(model) }
                encoderPendingRemoval = nil
            }
        } message: {
            Text("The speech model stays downloaded. Transcription can continue without Neural Engine acceleration.")
        }
    }

    private func modelRow(_ model: WhisperModelDescriptor) -> some View {
        let prepared = appState.isWhisperModelPrepared(model)
        let selected = model == appState.whisperConfiguration.model
        let downloading = appState.isDownloadingWhisperModel(model)
        let encoderDownloading = appState.isDownloadingWhisperEncoder(model)
        let error = appState.whisperDownloadError(for: model)
        let encoderError = appState.whisperEncoderDownloadError(for: model)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                EmberProviderIcon(asset: "provider-openai", size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Whisper \(model.displayName)").font(.system(size: 14, weight: .medium))
                    Text("\(model.approximateDiskSizeDescription) · Multilingual").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    Text(model.detailText).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    if downloading {
                        Button("Cancel") { appState.cancelWhisperModelDownload(model) }.buttonStyle(EmberButtonStyle())
                    } else if selected && prepared {
                        Label("Selected", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(AppTheme.accent)
                    } else if prepared {
                        HStack(spacing: 4) {
                            Button("Use") { appState.updateWhisperModel(model) }
                                .buttonStyle(EmberButtonStyle()).disabled(appState.whisperSettingsLocked)
                            if !encoderDownloading { encoderMenu(model) }
                        }
                    } else {
                        Button(error == nil ? "Download" : "Retry") { downloadModel(model) }
                        .buttonStyle(EmberButtonStyle(primary: true))
                        .disabled(appState.whisperSettingsLocked)
                    }
                    if prepared && !selected {
                        Button { removeModel(model) } label: { Image(systemName: "trash") }
                            .buttonStyle(EmberIconButtonStyle())
                            .disabled(!appState.canDeleteWhisperModel(model) || appState.whisperSettingsLocked || encoderDownloading)
                            .help(appState.canDeleteWhisperModel(model) ? "Remove Whisper \(model.displayName)" : "Keep at least one downloaded speech model.")
                            .accessibilityLabel("Remove Whisper \(model.displayName)")
                    }
                }
            }
            if downloading {
                progress(appState.whisperDownloadProgress(for: model), status: appState.whisperDownloadStatusText(for: model))
            }
            if encoderDownloading {
                HStack {
                    Text("Encoder · \(appState.whisperEncoderDownloadStatusText(for: model))").font(.system(size: 11))
                    Spacer()
                    Button("Cancel encoder") { appState.cancelWhisperEncoderDownload(model) }.buttonStyle(.plain).font(.system(size: 12))
                }
                EmberDownloadProgress(value: appState.whisperEncoderDownloadProgress(for: model))
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(AppTheme.errorText).textSelection(.enabled) }
            if let encoderError { Text(encoderError).font(.system(size: 12)).foregroundStyle(AppTheme.errorText).textSelection(.enabled) }
        }
        .padding(.vertical, 17).padding(.horizontal, error != nil || encoderError != nil ? 12 : 0)
        .background(error != nil || encoderError != nil ? AppTheme.errorFill : .clear, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            if error != nil || encoderError != nil { RoundedRectangle(cornerRadius: 16).stroke(AppTheme.errorBorder, lineWidth: 1) }
        }
    }

    private func encoderMenu(_ model: WhisperModelDescriptor) -> some View {
        Menu {
            if appState.isWhisperEncoderDownloaded(model) {
                Toggle("Use encoder", isOn: Binding(get: { appState.isWhisperEncoderEnabled(model) }, set: { appState.setWhisperEncoderEnabled($0, for: model) }))
                Button("Remove encoder…", role: .destructive) { encoderPendingRemoval = model }
            } else {
                Button("Download encoder…") { downloadEncoder(model) }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 22, height: 25) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(appState.whisperSettingsLocked)
        .accessibilityLabel("Encoder actions for Whisper \(model.displayName)")
    }

    private var encoderControls: some View {
        let model = appState.whisperConfiguration.model
        return VStack(alignment: .leading, spacing: 12) {
            Text("Whisper \(model.displayName) encoder · \(model.encoderApproximateSizeDescription). Dictation also works without this download.")
                .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            if appState.isDownloadingWhisperEncoder(model) {
                Text("The encoder download is shown in the model row above.").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            } else if appState.isWhisperEncoderDownloaded(model) {
                HStack {
                    Toggle("Use encoder", isOn: Binding(get: { appState.isWhisperEncoderEnabled(model) }, set: { appState.setWhisperEncoderEnabled($0, for: model) }))
                        .toggleStyle(.switch).controlSize(.mini)
                    Spacer(minLength: 12)
                    if !appState.isWhisperEncoderEnabled(model) {
                        Button("Remove encoder…") { encoderPendingRemoval = model }.buttonStyle(EmberButtonStyle())
                    }
                }
                if appState.isWhisperEncoderEnabled(model) {
                    Text("Turn off the encoder to remove it.")
                        .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                }
            } else {
                Button(appState.whisperEncoderDownloadError(for: model) == nil ? "Download encoder…" : "Retry encoder…") { downloadEncoder(model) }
                    .buttonStyle(EmberButtonStyle())
                    .disabled(!appState.isWhisperModelPrepared(model))
            }
        }
        .disabled(appState.whisperSettingsLocked)
    }

    private func progress(_ value: Double?, status: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            EmberDownloadProgress(value: value)
            Text(status).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
        }
    }
}
