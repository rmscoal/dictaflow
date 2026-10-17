import SwiftUI

struct HistoryView: View {
    @ObservedObject var appState: DictaFlowAppState
    @ObservedObject var model: HistoryViewModel
    @State private var showsCompactDetail = false
    @State private var showsSettings = false
    @State private var confirmsDelete = false
    @State private var confirmsDeleteAll = false
    @State private var pendingRetention: HistoryRetention?
    @State private var pendingDeletionCount = 0
    private var canMutate: Bool { appState.canProcessHistory && !model.isMutating }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmberPageHeading(title: "Recording history")
            if let error = model.errorMessage {
                EmberErrorBanner(title: "History needs attention", message: error, actionTitle: "Dismiss") { model.errorMessage = nil }
                    .padding(.bottom, 16)
            }
            HStack {
                Text(appState.historyRetention == .off ? "History is off · existing recordings keep their expiry" : "Kept for \(appState.historyRetention.rawValue) days")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Button { showsSettings = true } label: { Label("History settings", systemImage: "gearshape") }
                    .buttonStyle(.plain).font(.system(size: 12))
                    .popover(isPresented: $showsSettings, arrowEdge: .top) { settings }
            }
            .padding(.bottom, 16)
            GeometryReader { geometry in
                if geometry.size.width < 620 {
                    if showsCompactDetail, model.selectedID != nil {
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                showsCompactDetail = false
                                Task { await model.stopPlayback() }
                            } label: {
                                Label("All recordings", systemImage: "chevron.left")
                            }
                            .buttonStyle(EmberButtonStyle()).padding(14)
                            EmberDivider()
                            recordingDetail(compact: true)
                        }
                    } else {
                        recordingList
                    }
                } else {
                    HStack(spacing: 0) {
                        recordingList.frame(width: min(330, max(240, geometry.size.width * 0.32)))
                        Rectangle().fill(AppTheme.border).frame(width: 1)
                        recordingDetail().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(AppTheme.border, lineWidth: 1) }
        }
        .padding(.horizontal, AppLayout.contentPadding).padding(.top, 10).padding(.bottom, 28)
        .task(id: model.searchQuery) {
            let query = model.searchQuery
            await model.refresh()
            guard !Task.isCancelled, query == model.searchQuery else { return }
            if model.selectedID == nil, let first = model.entries.first { await model.select(first.id) }
        }
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

    private var recordingList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondaryText)
                TextField("Search history", text: Binding(get: { model.searchQuery }, set: { model.updateSearchQuery($0) }))
                    .textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel("Search recordings")
            }
            .padding(11).background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 10)).padding(14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if model.isLoading && (model.entries.isEmpty || model.isReplacingSearchResults) {
                        ProgressView("Loading recordings…").font(.system(size: 12)).padding(20)
                    } else if model.entries.isEmpty {
                        Text(model.searchQuery.isEmpty ? "No recordings yet." : "No matching recordings.")
                            .font(.system(size: 13)).foregroundStyle(AppTheme.secondaryText).padding(20)
                    } else {
                        ForEach(recordingDays, id: \.self) { day in
                            Text(dayTitle(day)).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
                            ForEach(model.entries.filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: day) }) { entry in
                                Button {
                                    showsCompactDetail = true
                                    Task { await model.select(entry.id) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                        Text("\(entry.capturedAt.formatted(date: .omitted, time: .shortened)) · \(formatDuration(entry.duration))")
                                            .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                                        if appState.processingHistoryID == entry.id {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(model.selectedID == entry.id ? AppTheme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain).accessibilityAddTraits(model.selectedID == entry.id ? .isSelected : [])
                            }
                        }
                        if model.hasMore {
                            Button("Load more") { Task { await model.refresh(loadMore: true) } }
                                .buttonStyle(EmberButtonStyle()).disabled(model.isLoading).padding(12)
                        }
                    }
                }
                .padding(.horizontal, 9).padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder private func recordingDetail(compact: Bool = false) -> some View {
        if model.isLoading && model.isReplacingSearchResults {
            ProgressView("Searching history…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail = model.detail, detail.entry.id == model.selectedID {
            HistoryDetailView(appState: appState, model: model, detail: detail, confirmsDelete: $confirmsDelete, scrollsEntireDetail: compact).id(detail.entry.id)
        } else if model.selectedID != nil {
            ProgressView("Loading recording…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.bubble").font(.system(size: 24)).foregroundStyle(AppTheme.secondaryText)
                Text(model.searchQuery.isEmpty ? "Select a recording" : "No recording matches your search").font(.system(size: 17, weight: .medium))
                Text(model.searchQuery.isEmpty ? "Finished recordings and their results appear here." : "Try another word.")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("History settings").font(.system(size: 17, weight: .medium))
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
                .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            EmberDivider()
            Button("Delete all history…", role: .destructive) { showsSettings = false; confirmsDeleteAll = true }
                .disabled(!canMutate)
        }
        .padding(20).frame(width: 320).foregroundStyle(AppTheme.primaryText).background(AppTheme.tileFill)
    }

    private var recordingDays: [Date] {
        Array(Set(model.entries.map { Calendar.current.startOfDay(for: $0.capturedAt) })).sorted(by: >)
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
