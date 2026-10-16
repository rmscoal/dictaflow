import SwiftUI

struct HistoryDetailView: View {
    @ObservedObject var appState: DictaFlowAppState
    @ObservedObject var model: HistoryViewModel
    let detail: HistoryDetail
    @Binding var confirmsDelete: Bool
    @State private var showsPreviousResults = false
    @State private var showsRetryConfirmation = false
    @State private var retryModel: WhisperModelDescriptor?

    private var hasText: Bool { model.displayedText != nil }
    private var canMutate: Bool { appState.canProcessHistory && !model.isMutating }
    private var isRetrying: Bool { appState.processingHistoryID == detail.entry.id }
    private var hasPreviousResults: Bool { detail.transcriptions.count > 1 || model.refinements.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.entry.title).font(.system(size: 17, weight: .medium)).lineLimit(2)
                Text("\(detail.entry.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(formatDuration(detail.entry.duration))")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { primaryActions }
                VStack(alignment: .leading, spacing: 10) { primaryActions }
            }
            HistoryPlaybackView(player: model.player, recordingDuration: detail.entry.duration, isLoading: model.isPlaybackLoading,
                                available: detail.entry.audioAvailable && !model.isPlaybackLoading && !appState.isHistoryProcessing && !model.isMutating && appState.recordingState == .idle) {
                Task { await model.togglePlayback() }
            }
            .padding(.horizontal, 12).background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 12))
            if isRetrying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(appState.historyProcessingStatusText).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                }
            } else if let message = model.retryMessages[detail.entry.id] {
                Text(message).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            }
            textViewPicker
            if !hasText {
                EmberErrorBanner(title: "No text result", message: missingText)
            }
            ScrollView {
                Text(model.displayedText ?? "").font(.system(size: 16)).lineSpacing(7).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            sourceLabel
            if showsPreviousResults { previousResults }
        }
        .padding(24)
    }

    @ViewBuilder private var primaryActions: some View {
        Button {
            if let text = model.displayedText { appState.copyHistoryText(text) }
        } label: { Label("Copy", systemImage: "doc.on.doc") }
        .buttonStyle(EmberButtonStyle()).disabled(!hasText)
        Button { appState.insertHistoryText() } label: { Label("Insert again", systemImage: "arrow.up.right") }
            .buttonStyle(EmberButtonStyle()).disabled(!canMutate || !hasText)
        Button {
            retryModel = appState.whisperConfiguration.model
            showsRetryConfirmation = true
        } label: { Label("Retry", systemImage: "arrow.clockwise") }
        .buttonStyle(EmberButtonStyle()).disabled(!canMutate || !detail.entry.audioAvailable)
        .popover(isPresented: $showsRetryConfirmation, arrowEdge: .top) { retryConfirmation }
        Menu {
            Button(model.refinements.isEmpty ? "Refine text" : "Refine again") { appState.retryHistoryRefinement() }
                .disabled(!canMutate || model.transcription?.result?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || !appState.isSelectedRefinementModelPrepared)
            Button(showsPreviousResults ? "Hide previous results" : "Previous results") { showsPreviousResults.toggle() }
                .disabled(!hasPreviousResults)
            Text("Deletes \(detail.entry.expiresAt.formatted(date: .abbreviated, time: .omitted))")
            Divider()
            Button("Delete recording…", role: .destructive) { confirmsDelete = true }.disabled(!canMutate)
        } label: { Image(systemName: "ellipsis").frame(width: 25, height: 29) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More recording actions")
    }

    @ViewBuilder private var textViewPicker: some View {
        if !model.refinements.isEmpty || model.hasToneFormatting {
            Picker("Text view", selection: $model.textView) {
                Text("Original").tag(HistoryViewModel.TextView.original)
                if model.refinement?.result != nil { Text("Refined").tag(HistoryViewModel.TextView.refined) }
                Text("Final").tag(HistoryViewModel.TextView.final)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceLabel: some View {
        HStack(spacing: 9) {
            if model.textView == .original {
                EmberProviderIcon(asset: "provider-openai", size: 25)
                Text("Whisper \(model.transcription?.configuration.model.displayName ?? "")")
            } else if model.textView == .refined, let refinement = model.refinement {
                if let provider = refinement.configuration.model.provider { EmberProviderIcon(asset: provider.iconName, size: 25) }
                Text(refinement.configuration.model.displayName)
            } else {
                EmberAppMark(size: 25)
                Text("\((model.refinement?.result?.toneFormatting?.tone ?? model.transcription?.result?.toneFormatting?.tone ?? .original).title) tone")
            }
            if let transcription = model.transcription { Text("· \(model.transcriptionLabel(transcription))") }
        }
        .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
    }

    private var retryConfirmation: some View {
        let selectedModel = retryModel ?? appState.whisperConfiguration.model
        return VStack(alignment: .leading, spacing: 14) {
            Text("Retry transcription?").font(.system(size: 17, weight: .medium))
            Picker("Model", selection: Binding(get: { selectedModel }, set: { retryModel = $0 })) {
                ForEach(WhisperModelDescriptor.allCases, id: \.self) { descriptor in
                    Text("Whisper \(descriptor.displayName)").tag(descriptor).disabled(!appState.isWhisperModelPrepared(descriptor))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Task", value: appState.whisperConfiguration.taskMode.title)
                LabeledContent("Language", value: appState.whisperConfiguration.inputLanguage.displayName)
                LabeledContent("Tone", value: appState.textTone.title)
                LabeledContent("Refinement", value: appState.refinementConfiguration.isEnabled ? "On" : "Off")
            }
            Text("Processes the saved audio again. Previous results are kept. Text will not be inserted automatically.")
                .foregroundStyle(AppTheme.secondaryText)
            if !appState.isWhisperModelPrepared(selectedModel) {
                Text("Download this model in Dictation → Transcription before retrying.").foregroundStyle(AppTheme.errorText)
            }
            if appState.refinementConfiguration.isEnabled && !appState.isSelectedRefinementModelPrepared {
                Text("The refinement model is unavailable. This retry will use the transcript with your selected tone.")
                    .foregroundStyle(AppTheme.errorText)
            }
            HStack {
                Spacer()
                Button("Cancel") { showsRetryConfirmation = false }.buttonStyle(EmberButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Retry") {
                    showsRetryConfirmation = false
                    appState.retryHistoryTranscription(model: retryModel)
                }
                .buttonStyle(EmberButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(!canMutate || model.selectedID != detail.entry.id || !detail.entry.audioAvailable || !appState.isWhisperModelPrepared(selectedModel))
            }
        }
        .font(.system(size: 12)).padding(20).frame(width: 340)
        .foregroundStyle(AppTheme.primaryText).background(AppTheme.tileFill)
    }

    private var previousResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Previous results").font(.system(size: 13, weight: .medium))
                Spacer()
                Button { showsPreviousResults = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close previous results")
            }
            Picker("Transcription", selection: $model.selectedTranscriptionID) {
                ForEach(detail.transcriptions) { result in
                    Text("\(model.transcriptionLabel(result)) · \(resultStatusTitle(result.status))").tag(Optional(result.id))
                }
            }
            .onChange(of: model.selectedTranscriptionID) { _, _ in model.selectTranscription() }
            if !model.refinements.isEmpty {
                Picker("Refinement", selection: $model.selectedRefinementID) {
                    ForEach(model.refinements) { result in
                        Text("\(model.refinementLabel(result)) · \(resultStatusTitle(result.status))").tag(Optional(result.id))
                    }
                }
            }
        }
        .font(.system(size: 12)).padding(14)
        .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private var missingText: String {
        if model.showsOriginal || (!model.showsRawRefinement && model.refinement?.result == nil) {
            if model.transcription?.result != nil { return "No speech was detected. Replay the audio or try again." }
            return model.transcription?.errorMessage ?? "No transcription yet. Replay the saved audio or try again."
        }
        return model.refinement?.errorMessage ?? "No refined text for this result. Switch to Original to read its transcription."
    }
}
