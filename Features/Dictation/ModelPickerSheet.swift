import SwiftUI

struct ModelPickerSheet: View {
    @ObservedObject var appState: DictaFlowAppState
    let presentation: ModelPickerPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var provider: RefinementProvider
    @State private var speechProvider: SpeechRecognitionProvider
    @State private var downloadRequest: ModelDownloadRequest?
    @State private var removalRequest: ModelRemovalRequest?

    init(appState: DictaFlowAppState, presentation: ModelPickerPresentation) {
        self.appState = appState
        self.presentation = presentation
        let focused = RefinementModelDescriptor.allCases.first { $0.modelIdentifier == presentation.modelIdentifier }
        _provider = State(initialValue: focused?.provider ?? appState.refinementConfiguration.model.provider ?? .qwen)
        if presentation.kind == .speech,
           let identifier = presentation.modelIdentifier,
           WhisperModelDescriptor.allCases.contains(where: { $0.modelIdentifier == identifier }) {
            _speechProvider = State(initialValue: .whisper)
        } else {
            _speechProvider = State(initialValue: appState.whisperConfiguration.recognitionProvider)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.kind == .speech ? "Choose a speech model" : "Choose a refinement model")
                        .font(.system(size: 21, weight: .medium))
                }
                Spacer(minLength: 0)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(EmberIconButtonStyle()).accessibilityLabel("Close model picker")
            }
            .padding(22)
            if let issue = appState.interfaceIssue, issue.severity == .error {
                EmberErrorBanner(title: issue.title, message: issue.message, actionTitle: "Dismiss") { appState.dismissInterfaceIssue() }
                    .padding(.horizontal, 22).padding(.bottom, 16)
            }
            EmberDivider()
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        Group {
                            if presentation.kind == .speech {
                                VStack(alignment: .leading, spacing: 18) {
                                    speechProviderPills
                                    if speechProvider == .whisper {
                                        WhisperModelsView(appState: appState,
                                            downloadModel: { downloadRequest = .speech($0, includeEncoder: false) },
                                            downloadEncoder: { downloadRequest = .encoder($0) },
                                            removeModel: { removalRequest = .speech($0) })
                                    } else {
                                        liquidSpeechSection
                                    }
                                }
                            } else {
                                RefinementModelsView(appState: appState, provider: $provider,
                                    downloadModel: { downloadRequest = .refinement($0) },
                                    removeModel: { removalRequest = .refinement($0) })
                            }
                        }
                        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onAppear { focus(presentation.modelIdentifier, proxy: proxy) }
                    .onChange(of: appState.modelPickerPresentation?.modelIdentifier) { _, identifier in
                        focus(identifier, proxy: proxy)
                    }
                    EmberDivider()
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        Button("Done") { dismiss() }.buttonStyle(EmberButtonStyle()).keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(AppTheme.background, in: Rectangle())
                }
            }
        }
        .frame(width: 610, height: 650)
        .foregroundStyle(AppTheme.primaryText).background(AppTheme.tileFill).tint(AppTheme.accent)
        .sheet(item: $downloadRequest) { request in
            ModelDownloadConfirmation(appState: appState, request: request)
        }
        .alert("Remove \(removalRequest?.name ?? "model")?", isPresented: Binding(
            get: { removalRequest != nil }, set: { if !$0 { removalRequest = nil } }
        ), presenting: removalRequest) { request in
            Button("Cancel", role: .cancel) { removalRequest = nil }
            Button("Remove", role: .destructive) {
                switch request {
                case .speech(let model): appState.deleteWhisperModel(model)
                case .refinement(let model): appState.deleteRefinementModel(model)
                }
                removalRequest = nil
            }
        } message: { request in
            Text(request.message(appState: appState))
        }
    }

    private func focus(_ identifier: String?, proxy: ScrollViewProxy) {
        guard let identifier else { return }
        if let model = RefinementModelDescriptor.allCases.first(where: { $0.modelIdentifier == identifier }), let next = model.provider {
            provider = next
        }
        if WhisperModelDescriptor.allCases.contains(where: { $0.modelIdentifier == identifier }) {
            speechProvider = .whisper
        }
        proxy.scrollTo(identifier, anchor: .top)
    }

    /// Provider pills for speech models, mirroring the refinement picker.
    /// Selecting a provider's model moves the recognition engine with it.
    private var speechProviderPills: some View {
        HStack(spacing: 8) {
            ForEach(SpeechRecognitionProvider.allCases) { item in
                Button { speechProvider = item } label: {
                    HStack(spacing: 6) {
                        EmberProviderIcon(asset: item.iconName, size: 22)
                        Text(item.compactTitle).font(.system(size: 12))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .foregroundStyle(speechProvider == item ? AppTheme.accent : AppTheme.primaryText)
                    .background(speechProvider == item ? AppTheme.selectedFill : AppTheme.tileFill, in: Capsule())
                    .overlay { Capsule().stroke(speechProvider == item ? AppTheme.accent : AppTheme.border, lineWidth: 1) }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityLabel(item.title)
                .accessibilityAddTraits(speechProvider == item ? .isSelected : [])
            }
        }
    }

    private var liquidSpeechSection: some View {
        let ready = appState.agentVoice?.isModelReady == true
        let downloading = appState.agentVoice?.isDownloading == true
        let selected = appState.whisperConfiguration.recognitionProvider == .liquid
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                EmberProviderIcon(asset: SpeechRecognitionProvider.liquid.iconName, size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Liquid LFM3-Audio-2B").font(.system(size: 14, weight: .medium))
                    Text("1.4 GB · Audio model").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    Text("On-device transcription for everyday dictation.")
                        .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    if downloading {
                        Text("Downloading…").font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                    } else if selected && ready {
                        Label("Selected", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(AppTheme.accent)
                    } else if ready {
                        Button("Use") { appState.updateSpeechToLiquid() }
                            .buttonStyle(EmberButtonStyle())
                            .disabled(appState.whisperSettingsLocked)
                    } else {
                        Button("Download") { appState.showMainWindowPage(.agentVoice) }
                            .buttonStyle(EmberButtonStyle(primary: true))
                            .disabled(appState.whisperSettingsLocked)
                    }
                }
            }
            if !ready && !downloading {
                Text("Download its shared assets in Agent Voice, under Models.")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(.vertical, 17)
        .id("speech.liquid")
    }
}

private enum ModelRemovalRequest {
    case speech(WhisperModelDescriptor), refinement(RefinementModelDescriptor)
    var name: String {
        switch self { case .speech(let model): "Whisper \(model.displayName)"; case .refinement(let model): model.displayName }
    }
    func message(appState: DictaFlowAppState) -> String {
        let includesEncoder: Bool
        switch self { case .speech(let model): includesEncoder = appState.isWhisperEncoderDownloaded(model); case .refinement: includesEncoder = false }
        return includesEncoder ? "The model and its encoder will be removed from this Mac. Saved history is kept. You can download them again later." : "The model file will be removed from this Mac. Saved history is kept. You can download it again later."
    }
}

private enum ModelDownloadRequest: Identifiable {
    case speech(WhisperModelDescriptor, includeEncoder: Bool)
    case encoder(WhisperModelDescriptor)
    case refinement(RefinementModelDescriptor)
    var id: String {
        switch self {
        case .speech(let model, _): model.modelIdentifier
        case .encoder(let model): model.encoderModelIdentifier
        case .refinement(let model): model.modelIdentifier
        }
    }
    var name: String {
        switch self {
        case .speech(let model, _): "Whisper \(model.displayName)"
        case .encoder(let model): "Whisper \(model.displayName) encoder"
        case .refinement(let model): model.displayName
        }
    }
    var size: String {
        switch self {
        case .speech(let model, _): model.approximateDiskSizeDescription
        case .encoder(let model): model.encoderApproximateSizeDescription
        case .refinement(let model): model.approximateDiskSizeDescription
        }
    }
}

private struct ModelDownloadConfirmation: View {
    @ObservedObject var appState: DictaFlowAppState
    let request: ModelDownloadRequest
    @Environment(\.dismiss) private var dismiss
    @State private var includeEncoder: Bool

    init(appState: DictaFlowAppState, request: ModelDownloadRequest) {
        self.appState = appState
        self.request = request
        if case .speech(_, let includeEncoder) = request { _includeEncoder = State(initialValue: includeEncoder) }
        else { _includeEncoder = State(initialValue: false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Download \(request.name)?").font(.system(size: 21, weight: .medium))
            Text("\(request.size) of storage is required. Your current model stays selected while this model downloads.")
                .font(.system(size: 13)).foregroundStyle(AppTheme.secondaryText)
            if case .speech(let model, _) = request {
                Toggle(isOn: $includeEncoder) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Include Neural Engine encoder").font(.system(size: 13))
                        Text("Optional · \(model.encoderApproximateSizeDescription). Transcription also works without it.")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(EmberButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Download") {
                    switch request {
                    case .speech(let model, _):
                        if includeEncoder { appState.downloadWhisperModelWithEncoder(model) }
                        else { appState.downloadWhisperModel(model) }
                    case .encoder(let model): appState.downloadWhisperEncoder(model)
                    case .refinement(let model): appState.downloadRefinementModel(model)
                    }
                    dismiss()
                }
                .buttonStyle(EmberButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 425)
        .foregroundStyle(AppTheme.primaryText).background(AppTheme.tileFill).tint(AppTheme.accent)
    }
}
