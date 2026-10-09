import SwiftUI

struct HistoryView: View {
    @ObservedObject var appState: DictaFlowAppState
    @ObservedObject var model: HistoryViewModel
    @State private var showsSettings = false
    @State private var confirmsDelete = false
    @State private var confirmsDeleteAll = false
    @State private var pendingRetention: HistoryRetention?
    @State private var pendingDeletionCount = 0

    private var canMutate: Bool { appState.canProcessHistory && !model.isMutating }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") { model.errorMessage = nil }
                }
                .padding(12)
                .foregroundStyle(AppTheme.warning)
                .background(AppTheme.controlFill)
            }

            recordingFeed
        }
        .task { await model.refresh() }
        .onDisappear { Task { await model.stopPlayback() } }
        .alert("Delete Recording?", isPresented: $confirmsDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await model.deleteSelected() } }
        } message: { Text("This deletes the recording audio and all of its transcription and refinement results.") }
        .alert("Delete All History?", isPresented: $confirmsDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) { Task { await model.deleteAll() } }
        } message: { Text("This deletes all saved recording audio and results. This cannot be undone.") }
        .alert("Shorten History Retention?", isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })) {
            Button("Cancel", role: .cancel) { pendingRetention = nil }
            Button("Change and Delete \(pendingDeletionCount) \(pendingDeletionCount == 1 ? "Recording" : "Recordings")", role: .destructive) {
                let retention = pendingRetention
                pendingRetention = nil
                if let retention { Task { await appState.updateHistoryRetention(retention, confirmedDeletion: true) } }
            }
        } message: {
            Text("\(pendingDeletionCount) \(pendingDeletionCount == 1 ? "recording is" : "recordings are") older than \(pendingRetention?.rawValue ?? 7) days. Changing retention will delete \(pendingDeletionCount == 1 ? "this recording" : "these recordings") and all saved results. This cannot be undone.")
        }
    }

    private var emptyDescription: String {
        if appState.historyRetention == .off { return "History is off. Enable it in History Settings to save future recordings." }
        return "Finished recordings appear here. Cancelled recordings are discarded."
    }

    private var recordingFeed: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                if appState.isHistoryProcessing && appState.processingHistoryID == nil {
                    ProgressView().controlSize(.small)
                }
                Button("History settings", systemImage: "gearshape") { showsSettings = true }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .help("History settings")
                    .accessibilityLabel("History settings")
                    .popover(isPresented: $showsSettings, arrowEdge: .leading) { settings }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.entries.isEmpty && model.isLoading {
                        ProgressView("Loading history…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if model.entries.isEmpty {
                        ContentUnavailableView(
                            "No Recordings",
                            systemImage: "text.bubble",
                            description: Text(emptyDescription)
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    ForEach(recordingDays, id: \.self) { day in
                        Text(dayTitle(day))
                            .font(.headline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(model.entries.filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: day) }) { entry in
                            recordingCard(entry)
                        }
                    }
                    if model.hasMore {
                        Button {
                            Task { await model.refresh(loadMore: true) }
                        } label: {
                            if model.isLoading { ProgressView("Loading recordings…").controlSize(.small) }
                            else { Text("Load More") }
                        }
                            .disabled(model.isLoading)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    Text(appState.historyRetention == .off ? "History is off. Existing recordings keep their expiry." : "Recordings are kept for \(appState.historyRetention.rawValue) days")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
    }

    private func recordingCard(_ entry: HistoryEntry) -> some View {
        let selected = model.selectedID == entry.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await model.toggleSelection(entry.id) }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(entry.capturedAt.formatted(date: .omitted, time: .shortened)) · \(formatDuration(entry.duration))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                        Spacer()
                        if !selected && appState.processingHistoryID == entry.id {
                            ProgressView().controlSize(.small)
                            Text(appState.historyProcessingStatusText)
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                        Image(systemName: selected ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    if !selected {
                        Text(entry.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entryStatus(entry) : entry.preview)
                            .font(.system(size: 16))
                            .lineSpacing(4)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected ? "Collapse recording" : "Expand recording: \(entry.title)")
            .accessibilityValue(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))

            if selected {
                if let detail = model.detail, detail.entry.id == entry.id {
                    HistoryCardContent(appState: appState, model: model, detail: detail, confirmsDelete: $confirmsDelete)
                        .id(entry.id)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 20)
                }
            }
        }
        .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? AppTheme.secondaryText.opacity(0.4) : AppTheme.border, lineWidth: 1))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("History Settings").font(.headline)
            Picker("Keep history", selection: Binding(get: { appState.historyRetention }, set: { value in
                Task {
                    if let count = await appState.updateHistoryRetention(value) {
                        pendingDeletionCount = count
                        showsSettings = false
                        pendingRetention = value
                    }
                }
            })) {
                ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!canMutate)
            Text("Audio and text expire together. Off stops saving new recordings; existing entries keep their expiry.")
                .font(.callout).foregroundStyle(AppTheme.secondaryText)
            Divider()
            Button("Delete All History…", role: .destructive) { showsSettings = false; confirmsDeleteAll = true }
                .disabled(!canMutate)
        }
        .padding(20)
        .frame(width: 320)
    }

    private var recordingDays: [Date] {
        Array(Set(model.entries.map { Calendar.current.startOfDay(for: $0.capturedAt) })).sorted(by: >)
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func entryStatus(_ entry: HistoryEntry) -> String {
        if !entry.audioAvailable { return "Audio unavailable" }
        switch entry.status {
        case .failed: return "Transcription failed"
        case .interrupted: return "Processing interrupted"
        case .running: return "Transcribing"
        case .unprocessed: return "Ready to transcribe"
        case .succeeded: return "No speech detected"
        }
    }
}

private struct HistoryCardContent: View {
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
        VStack(alignment: .leading, spacing: 18) {
            if let transcription = model.transcription {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.transcriptionLabel(transcription)).font(.caption.weight(.medium))
                    Text("\(transcription.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(transcription.configuration.model.displayName)")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
            }
            Text(model.displayedText ?? missingText)
                .font(.system(size: 16))
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRetrying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(appState.historyProcessingStatusText)
                        .font(.callout).foregroundStyle(AppTheme.secondaryText)
                }
            }

            if !isRetrying, let message = model.retryMessages[detail.entry.id] {
                Text(message).font(.callout).foregroundStyle(AppTheme.secondaryText)
            }

            HistoryPlaybackView(player: model.player, recordingDuration: detail.entry.duration, isLoading: model.isPlaybackLoading, available: detail.entry.audioAvailable && !model.isPlaybackLoading && !appState.isHistoryProcessing && !model.isMutating && appState.recordingState == .idle) {
                Task { await model.togglePlayback() }
            }
            .padding(.horizontal, 12)
            .background(AppTheme.editorFill, in: RoundedRectangle(cornerRadius: 10))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    textViewPicker
                    Spacer(minLength: 12)
                    actions
                }
                VStack(alignment: .leading, spacing: 12) {
                    textViewPicker
                    HStack { Spacer(); actions }
                }
            }

            if showsPreviousResults {
                previousResults
            }
        }
    }

    @ViewBuilder
    private var textViewPicker: some View {
        if !model.refinements.isEmpty {
            Picker("Text view", selection: $model.showsOriginal) {
                Text("Original").tag(true)
                Text("Refined").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Button {
                if let text = model.displayedText { appState.copyHistoryText(text) }
            } label: { Image(systemName: "doc.on.doc") }
            .disabled(!hasText)
            .help("Copy displayed text")
            .accessibilityLabel("Copy transcription")

            Button("Retry", systemImage: "arrow.clockwise") {
                retryModel = nil
                showsRetryConfirmation = true
            }
            .popover(isPresented: $showsRetryConfirmation, arrowEdge: .leading) { retryConfirmation }
                .disabled(!canMutate || !detail.entry.audioAvailable)
                .help("Transcribe again using current settings")

            Menu {
                Menu("Retry with Another Model") {
                    ForEach(WhisperModelDescriptor.allCases, id: \.self) { descriptor in
                        Button(descriptor.displayName) {
                            retryModel = descriptor
                            showsRetryConfirmation = true
                        }
                            .disabled(!canMutate || !appState.isWhisperModelPrepared(descriptor) || !detail.entry.audioAvailable)
                    }
                }
                .disabled(!canMutate || !detail.entry.audioAvailable)
                Button(model.refinements.isEmpty ? "Refine Text" : "Refine Again") { appState.retryHistoryRefinement() }
                    .disabled(!canMutate || model.transcription?.result?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || !appState.isSelectedRefinementModelPrepared)
                Button("Insert Again") { appState.insertHistoryText() }
                    .disabled(!canMutate || !hasText)
                Divider()
                Button(showsPreviousResults ? "Hide Previous Results" : "Previous Results") { showsPreviousResults.toggle() }
                    .disabled(!hasPreviousResults)
                Text("Deletes \(detail.entry.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                Divider()
                Button("Delete Recording…", role: .destructive) { confirmsDelete = true }
                    .disabled(!canMutate)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Recording actions")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
    }

    private var retryConfirmation: some View {
        let selectedModel = retryModel ?? appState.whisperConfiguration.model
        return VStack(alignment: .leading, spacing: 14) {
            Text("Retry Transcription?").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Model", value: selectedModel.displayName)
                LabeledContent("Task", value: appState.whisperConfiguration.taskMode.title)
                LabeledContent("Language", value: appState.whisperConfiguration.inputLanguage.displayName)
                LabeledContent("Refinement", value: appState.refinementConfiguration.isEnabled ? "On" : "Off")
            }
            .font(.callout)
            Text("Processes the saved audio again with speech detection. Previous results are kept. Text will not be inserted automatically.")
                .font(.callout).foregroundStyle(AppTheme.secondaryText)
            if !appState.isWhisperModelPrepared(selectedModel) {
                Text("Download this model from Models before retrying.")
                    .font(.callout).foregroundStyle(AppTheme.warning)
            }
            if appState.refinementConfiguration.isEnabled && !appState.isSelectedRefinementModelPrepared {
                Text("The refinement model is unavailable. This retry will keep the original text.")
                    .font(.callout).foregroundStyle(AppTheme.warning)
            }
            HStack {
                Spacer()
                Button("Cancel") { showsRetryConfirmation = false }
                    .keyboardShortcut(.cancelAction)
                Button("Retry") {
                    showsRetryConfirmation = false
                    appState.retryHistoryTranscription(model: retryModel)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canMutate || model.selectedID != detail.entry.id || !detail.entry.audioAvailable || !appState.isWhisperModelPrepared(selectedModel))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var previousResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Previous Results").font(.subheadline.weight(.medium))
                Spacer()
                Button { showsPreviousResults = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close previous results")
            }
            Text("Choose a saved attempt to read or copy. Retry keeps every result.")
                .font(.caption).foregroundStyle(AppTheme.secondaryText)
            Picker("Transcription", selection: $model.selectedTranscriptionID) {
                ForEach(detail.transcriptions) { result in
                    Text("\(model.transcriptionLabel(result)) · \(resultStatusTitle(result.status))")
                        .tag(Optional(result.id))
                }
            }
            .onChange(of: model.selectedTranscriptionID) { model.selectTranscription() }
            if !model.refinements.isEmpty {
                Picker("Refinement", selection: $model.selectedRefinementID) {
                    ForEach(model.refinements) { result in
                        Text("\(model.refinementLabel(result)) · \(resultStatusTitle(result.status))")
                            .tag(Optional(result.id))
                    }
                }
            }
        }
        .font(.caption)
        .padding(14)
        .background(AppTheme.editorFill, in: RoundedRectangle(cornerRadius: 10))
    }

    private var missingText: String {
        if model.showsOriginal {
            if model.transcription?.result != nil { return "No speech was detected. Replay the audio or try again." }
            return model.transcription?.errorMessage ?? "No transcription yet. Replay the saved audio or try again."
        }
        return model.refinement?.errorMessage ?? "No refined text for this result. Switch to Original to read its transcription."
    }
}

private struct HistoryPlaybackView: View {
    @ObservedObject var player: HistoryAudioPlayer
    let recordingDuration: TimeInterval
    let isLoading: Bool
    let available: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                if isLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
            }
                .buttonStyle(.bordered)
                .accessibilityLabel(isLoading ? "Loading Recording" : (player.isPlaying ? "Pause Recording" : "Play Recording"))
                .disabled(!available)
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                .disabled(player.duration == 0 || !available)
                .accessibilityLabel("Playback position")
            Text("\(formatDuration(player.position)) / \(formatDuration(player.duration > 0 ? player.duration : recordingDuration))")
                .font(.caption.monospacedDigit()).foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.vertical, 10)
    }
}

private func formatDuration(_ duration: TimeInterval) -> String {
    let seconds = max(Int(duration), 0)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

private func resultStatusTitle(_ status: HistoryAttemptStatus) -> String {
    switch status {
    case .succeeded: "Completed"
    case .failed: "Failed"
    case .interrupted: "Interrupted"
    case .running: "Processing"
    case .unprocessed: "Not processed"
    }
}
