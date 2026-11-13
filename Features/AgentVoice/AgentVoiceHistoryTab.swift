import AgentVoice
import AppKit
import SwiftUI

/// Sessions open directly into their retained conversation. Native turn IDs
/// and lifecycle events stay available through contextual exchange details.
struct AgentVoiceHistoryTab: View {
    @ObservedObject var voice: AgentVoiceCoordinator
    @ObservedObject var appState: DictaFlowAppState
    /// Uses the shared transient pasteboard writer for text and diagnostics.
    var onCopy: ((String) -> Void)?
    @State private var searchQuery = ""
    @State private var selectedSessionID: String?
    @State private var visibleSessionCount = AgentVoiceSessionGrouping.pageSize
    @State private var showsCompactDetail = false
    @State private var showsVoiceSettings = false
    @State private var showsSessionInfo = false
    @State private var detailRecordID: UUID?
    @State private var pendingDeletion: UUID?
    @State private var pendingSessionDeletion: AgentVoiceSessionGroup?
    @State private var pendingVoiceRetention: VoiceHistoryRetention?
    @State private var pendingVoiceDeletionCount = 0
    @State private var copiedConfirmation: String?
    @State private var expandedMessages: Set<String> = []
    @State private var selectedRenditions: [UUID: UUID] = [:]
    @State private var searchMatchIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            historyToolbar
            if let error = voice.replayError {
                EmberErrorBanner(title: "Could not replay response", message: error,
                                 actionTitle: "Dismiss") { voice.dismissReplayError() }
            }
            GeometryReader { geometry in
                if geometry.size.width < 620 {
                    if showsCompactDetail, selectedSession != nil {
                        VStack(alignment: .leading, spacing: 0) {
                            Button { showsCompactDetail = false } label: {
                                Label("All sessions", systemImage: "chevron.left")
                            }
                            .buttonStyle(EmberButtonStyle()).padding(12)
                            .accessibilityIdentifier("agent-voice-sessions-back")
                            EmberDivider()
                            sessionDetail
                        }
                    } else {
                        sessionList
                    }
                } else {
                    HStack(spacing: 0) {
                        sessionList.frame(width: min(300, max(220, geometry.size.width * 0.29)))
                        Rectangle().fill(AppTheme.border).frame(width: 1)
                        sessionDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border, lineWidth: 1) }
        }
        .onChange(of: searchQuery) { _, _ in
            visibleSessionCount = AgentVoiceSessionGrouping.pageSize
            selectedRenditions = [:]
            searchMatchIndex = 0
        }
        .onChange(of: selectedSession?.id) { _, _ in
            showsSessionInfo = false
            detailRecordID = nil
        }
        .alert("Delete this exchange?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Delete exchange", role: .destructive) {
                if let id = pendingDeletion { voice.deleteInteraction(id) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This removes the prompt, all its spoken revisions, and its playback history. This cannot be undone.")
        }
        .alert("Delete this session and its \(pendingSessionRecordIDs.count) \(pendingSessionRecordIDs.count == 1 ? "exchange" : "exchanges")?", isPresented: Binding(
            get: { pendingSessionDeletion != nil }, set: { if !$0 { pendingSessionDeletion = nil } }
        )) {
            Button("Delete session", role: .destructive) {
                voice.deleteInteractions(pendingSessionRecordIDs)
                pendingSessionDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingSessionDeletion = nil }
        } message: {
            Text("This removes every saved prompt, spoken revision, and playback attempt in this session. This cannot be undone.")
        }
        .alert("Shorten Voice History Retention?", isPresented: Binding(
            get: { pendingVoiceRetention != nil }, set: { if !$0 { pendingVoiceRetention = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingVoiceRetention = nil }
            Button("Change and Delete \(pendingVoiceDeletionCount) \(pendingVoiceDeletionCount == 1 ? "Interaction" : "Interactions")", role: .destructive) {
                let retention = pendingVoiceRetention
                pendingVoiceRetention = nil
                if let retention { Task { await appState.updateVoiceHistoryRetention(retention, confirmedDeletion: true) } }
            }
        } message: {
            Text("\(pendingVoiceDeletionCount) \(pendingVoiceDeletionCount == 1 ? "interaction is" : "interactions are") older than \(pendingVoiceRetention?.rawValue ?? 30) days. Changing retention will delete \(pendingVoiceDeletionCount == 1 ? "this interaction" : "these interactions") and all saved responses. This cannot be undone.")
        }
    }

    private var historyToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondaryText)
                TextField("Search conversations", text: $searchQuery)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityLabel("Search voice history")
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(AppTheme.secondaryText)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(10).background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 9))
            if voice.isSpeaking || voice.isGenerating {
                Button("Stop speech", systemImage: "stop.fill") { voice.stopSpeech() }
                    .buttonStyle(EmberButtonStyle())
                    .accessibilityIdentifier("agent-voice-history-stop")
            }
            Button { showsVoiceSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(EmberIconButtonStyle())
                .accessibilityLabel("Voice history settings").help("Voice history settings")
                .popover(isPresented: $showsVoiceSettings, arrowEdge: .top) { voiceSettings }
        }
    }

    private var voiceSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Voice history settings").font(.system(size: 17, weight: .medium))
            Picker("Keep voice history", selection: Binding(get: { appState.voiceHistoryRetention }, set: { value in
                Task {
                    if let count = await appState.updateVoiceHistoryRetention(value) {
                        pendingVoiceDeletionCount = count
                        showsVoiceSettings = false
                        pendingVoiceRetention = value
                    }
                }
            })) {
                ForEach(VoiceHistoryRetention.allCases) { Text($0.title).tag($0) }
            }
            Text("Spoken responses and prompts expire together. Up to 500 interactions are kept. Off stops saving new voice history; existing entries keep their expiry. Play regenerates speech from saved text.")
                .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
        }
        .padding(20).frame(width: 320).foregroundStyle(AppTheme.primaryText).background(AppTheme.tileFill)
    }

    private var sessions: [AgentVoiceSessionGroup] {
        AgentVoiceSessionGrouping.sessions(from: voice.history, matching: searchQuery)
    }

    private var visibleSessions: [AgentVoiceSessionGroup] { Array(sessions.prefix(visibleSessionCount)) }

    private var selectedSession: AgentVoiceSessionGroup? {
        sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    /// Resolve against current, unfiltered history, including inputs received
    /// while the confirmation is open. Search never changes deletion scope.
    private var pendingSessionRecordIDs: [UUID] {
        guard let session = pendingSessionDeletion else { return [] }
        return voice.history.filter {
            $0.interaction.session.host == session.host && $0.interaction.session.sessionID == session.sessionID
        }.map(\.id)
    }

    // MARK: - Sessions

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                if sessions.isEmpty {
                    Text(searchQuery.isEmpty ? "No conversations yet." : "No matching conversations.")
                        .font(.system(size: 13)).foregroundStyle(AppTheme.secondaryText).padding(20)
                } else {
                    ForEach(sessionDays, id: \.self) { day in
                        Text(dayTitle(day)).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                        ForEach(visibleSessions.filter { Calendar.current.isDate($0.lastActiveDate, inSameDayAs: day) }) { session in
                            sessionRow(session)
                        }
                    }
                    if visibleSessionCount < sessions.count {
                        Button("Load more") { visibleSessionCount += AgentVoiceSessionGrouping.pageSize }
                            .buttonStyle(EmberButtonStyle()).padding(12)
                            .accessibilityIdentifier("agent-voice-sessions-load-more")
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
    }

    private func sessionRow(_ session: AgentVoiceSessionGroup) -> some View {
        let isSelected = selectedSession?.id == session.id
        return Button {
            selectedSessionID = session.id
            showsCompactDetail = true
        } label: {
            HStack(alignment: .top, spacing: 10) {
                AgentVoiceHostIcon(brand: session.brand, size: 26)
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text(session.preview).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(session.brand.displayName)
                        if session.isLive { Text("· Active") }
                        Spacer(minLength: 4)
                        Text(session.lastActiveDate.formatted(date: .omitted, time: .shortened))
                    }
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(isSelected ? AppTheme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agent-voice-session-\(session.shortID)")
    }

    @ViewBuilder private var sessionDetail: some View {
        if let session = selectedSession {
            VStack(spacing: 0) {
                sessionHeader(session)
                EmberDivider()
                ScrollViewReader { proxy in
                    if !trimmedQuery.isEmpty { searchNavigation(session, proxy: proxy) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(session.records) { record in
                                transcriptExchange(record).id(record.id)
                            }
                        }
                        .frame(maxWidth: 720).frame(maxWidth: .infinity)
                        .padding(18)
                    }
                    .defaultScrollAnchor(.bottom)
                    .task(id: searchQuery) {
                        searchMatchIndex = 0
                        if let first = matchingRecords(in: session).first { proxy.scrollTo(first.id, anchor: .center) }
                    }
                }
                .id(session.id)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.bubble").font(.system(size: 24)).foregroundStyle(AppTheme.secondaryText)
                Text(searchQuery.isEmpty ? "Your conversations appear here" : "No matching conversations")
                    .font(.system(size: 16, weight: .medium))
                Text(searchQuery.isEmpty ? "Saved prompts and spoken replies stay together." : "Try another word.")
                    .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
        }
    }

    private func sessionHeader(_ session: AgentVoiceSessionGroup) -> some View {
        HStack(spacing: 10) {
            AgentVoiceHostIcon(brand: session.brand, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(session.brand.displayName + (session.isLive ? " · Active" : ""))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            }
            Spacer(minLength: 4)
            Button { showsSessionInfo = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(EmberIconButtonStyle())
                .accessibilityLabel("Session details").help("Session details")
                .popover(isPresented: $showsSessionInfo) { sessionInfo(session) }
            Button { pendingSessionDeletion = session } label: { Image(systemName: "trash") }
                .buttonStyle(EmberIconButtonStyle()).foregroundStyle(AppTheme.secondaryText)
                .accessibilityLabel("Delete session").help("Delete session")
                .accessibilityIdentifier("agent-voice-session-delete")
        }
        .padding(14)
    }

    private func sessionInfo(_ session: AgentVoiceSessionGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session details").font(.system(size: 16, weight: .medium))
            metadataRow("Session ID", value: session.sessionID, key: "session-\(session.id)")
            metadataRow("Started", value: session.startDate.formatted(date: .abbreviated, time: .standard), key: "start-\(session.id)")
            Text("\(session.interactionCount) saved \(session.interactionCount == 1 ? "exchange" : "exchanges") · \(session.brand.displayName)")
                .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
        }
        .padding(18).frame(width: 340)
    }

    private func metadataRow(_ title: String, value: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            HStack(alignment: .top, spacing: 8) {
                Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                copyIconButton(copyKey: key, accessibilityLabel: "Copy \(title.lowercased())") { copy(value, key: key) }
            }
        }
    }

    private func matchingRecords(in session: AgentVoiceSessionGroup) -> [VoiceHistoryRecord] {
        guard !trimmedQuery.isEmpty else { return [] }
        return session.records.filter { AgentVoiceSessionGrouping.matches($0, query: searchQuery) }
    }

    private func searchNavigation(_ session: AgentVoiceSessionGroup, proxy: ScrollViewProxy) -> some View {
        let matches = matchingRecords(in: session)
        let index = min(searchMatchIndex, max(0, matches.count - 1))
        return HStack(spacing: 8) {
            Text(matches.isEmpty ? "No matching exchanges" : "Match \(index + 1) of \(matches.count)")
                .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            Spacer(minLength: 4)
            Button {
                searchMatchIndex = max(0, index - 1)
                proxy.scrollTo(matches[searchMatchIndex].id, anchor: .center)
            } label: { Image(systemName: "chevron.up") }
            .disabled(matches.isEmpty || index == 0).accessibilityLabel("Previous match")
            Button {
                searchMatchIndex = min(matches.count - 1, index + 1)
                proxy.scrollTo(matches[searchMatchIndex].id, anchor: .center)
            } label: { Image(systemName: "chevron.down") }
            .disabled(matches.isEmpty || index == matches.count - 1).accessibilityLabel("Next match")
        }
        .buttonStyle(EmberIconButtonStyle()).padding(.horizontal, 14).padding(.vertical, 4)
    }

    // MARK: - Conversation bubbles

    private func transcriptExchange(_ record: VoiceHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prompt = record.interaction.promptText, !prompt.isEmpty {
                promptBubble(prompt, record: record)
            }
            renditionBubble(record)
        }
        .textSelection(.enabled)
        .popover(isPresented: Binding(
            get: { detailRecordID == record.id }, set: { if !$0 { detailRecordID = nil } }
        )) { exchangeDetails(record) }
    }

    private func promptBubble(_ prompt: String, record: VoiceHistoryRecord) -> some View {
        let key = "prompt-\(record.id)"
        return HStack(spacing: 0) {
            Spacer(minLength: 32)
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 8) {
                messageText(prompt, key: key)
                HStack(spacing: 10) {
                    copyIconButton(copyKey: key, accessibilityLabel: "Copy prompt") { copy(prompt, key: key) }
                    Spacer(minLength: 16)
                    timestamp(record.interaction.createdAt)
                }
                .gridCellUnsizedAxes(.horizontal)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(AppTheme.selectedFill, in: RoundedRectangle(cornerRadius: 13))
            .contextMenu { exchangeMenu(record) }
            .frame(maxWidth: 560, alignment: .trailing)
            .accessibilityElement(children: .contain).accessibilityLabel("Your message")
        }
    }

    @ViewBuilder private func renditionBubble(_ record: VoiceHistoryRecord) -> some View {
        let revisions = record.renditions.sorted { $0.revision < $1.revision }
        let fallback = revisions.first { $0.id == record.interaction.currentRenditionID } ?? revisions.last
        let matching = trimmedQuery.isEmpty ? nil : revisions.last { textMatchesSearch($0.text) }
        let displayed = selectedRenditions[record.id].flatMap { id in revisions.first { $0.id == id } } ?? matching ?? fallback
        HStack(spacing: 0) {
            if let displayed {
                let index = revisions.firstIndex { $0.id == displayed.id } ?? 0
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 8) {
                    messageText(displayed.text, key: "response-\(record.id)-\(displayed.revision)")
                    if revisions.count > 1 { revisionPicker(revisions, index: index, recordID: record.id) }
                    if let caption = revisionCaption(record: record, revision: displayed) {
                        Text(caption).font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        revisionActions(record: record, revision: displayed)
                        Spacer(minLength: 16)
                        timestamp(displayed.createdAt)
                    }
                    .gridCellUnsizedAxes(.horizontal)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 13))
                .contextMenu { exchangeMenu(record) }
                .frame(maxWidth: 560, alignment: .leading)
                .accessibilityElement(children: .contain).accessibilityLabel("Agent response")
            } else {
                Text(record.interaction.isSuppressed ? "Automatic speech stopped" : record.interaction.hostClosed ? "No spoken response saved" : "Waiting for a spoken response…")
                    .font(.system(size: 12)).italic().foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 13))
                    .contextMenu { exchangeMenu(record) }
                    .frame(maxWidth: 560, alignment: .leading)
            }
            Spacer(minLength: 32)
        }
    }

    @ViewBuilder private func exchangeMenu(_ record: VoiceHistoryRecord) -> some View {
        Button("Exchange details…", systemImage: "info.circle") { detailRecordID = record.id }
        Divider()
        Button("Delete exchange…", systemImage: "trash", role: .destructive) { pendingDeletion = record.id }
    }

    private func timestamp(_ date: Date) -> some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(AppTheme.secondaryText)
            .fixedSize()
            .help(date.formatted(date: .abbreviated, time: .standard))
    }

    private func revisionPicker(_ revisions: [VoiceRendition], index: Int, recordID: UUID) -> some View {
        HStack(spacing: 6) {
            Button { selectedRenditions[recordID] = revisions[index - 1].id } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0).accessibilityLabel("Previous revision")
            Text("Revision \(index + 1) of \(revisions.count)").font(.system(size: 11))
            Button { selectedRenditions[recordID] = revisions[index + 1].id } label: { Image(systemName: "chevron.right") }
                .disabled(index == revisions.count - 1).accessibilityLabel("Next revision")
        }
        .buttonStyle(EmberIconButtonStyle()).foregroundStyle(AppTheme.secondaryText)
    }

    private func revisionCaption(record: VoiceHistoryRecord, revision: VoiceRendition) -> String? {
        let attempts = record.attempts.filter { $0.renditionID == revision.id }
        if let active = attempts.first(where: { !$0.state.isTerminal }) {
            if active.state == .playing { return "Playing…" }
            if active.state == .synthesizing { return "Preparing audio…" }
            return "Queued"
        }
        if !voice.isEnabled { return "Enable Agent Voice in General to play." }
        if !voice.isModelReady { return "Download the speech model in General to play." }
        if let latest = attempts.max(by: { $0.createdAt < $1.createdAt }), latest.state == .failed {
            return "Playback failed" + (latest.failure.map { ": \($0)" } ?? ". Try again.")
        }
        if record.interaction.isSuppressed { return "Automatic speech stopped" }
        return nil
    }

    private func revisionActions(record: VoiceHistoryRecord, revision: VoiceRendition) -> some View {
        let active = record.attempts.first { $0.renditionID == revision.id && !$0.state.isTerminal }
        return HStack(spacing: 10) {
            if let active {
                if active.state == .playing || active.state == .synthesizing {
                    Button("Stop", systemImage: "stop.fill") { Task { await voice.stopPlayback(attemptID: active.id) } }
                        .buttonStyle(.plain).font(.system(size: 11))
                        .accessibilityLabel("Stop this response")
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Speech queued")
                }
            } else {
                Button("Play", systemImage: "play.fill") { Task { await voice.playRendition(revision.id) } }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(AppTheme.accent)
                    .disabled(!voice.isEnabled || !voice.isModelReady)
                    .accessibilityLabel("Play this revision")
            }
            copyIconButton(copyKey: "response-\(record.id)-\(revision.revision)", accessibilityLabel: "Copy response") {
                copy(revision.text, key: "response-\(record.id)-\(revision.revision)")
            }
        }
    }

    /// Only unusually long text is shortened, using a real text prefix rather
    /// than a character-based guess about line wrapping. Search reveals hits.
    private func messageText(_ text: String, key: String) -> some View {
        let canCollapse = text.count > 1_400 && !textMatchesSearch(text)
        let expanded = expandedMessages.contains(key)
        let displayed = canCollapse && !expanded ? String(text.prefix(1_400)) + "…" : text
        return VStack(alignment: .leading, spacing: 6) {
            highlightedText(displayed).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if canCollapse {
                Button(expanded ? "Show less" : "Show more") {
                    if expanded { expandedMessages.remove(key) } else { expandedMessages.insert(key) }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(AppTheme.accent)
            }
        }
    }

    private var trimmedQuery: String { searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func textMatchesSearch(_ text: String) -> Bool {
        !trimmedQuery.isEmpty && text.localizedCaseInsensitiveContains(trimmedQuery)
    }

    private func highlightedText(_ text: String) -> Text {
        var attributed = AttributedString(text)
        if !trimmedQuery.isEmpty {
            var start = text.startIndex
            while let range = text.range(of: trimmedQuery, options: .caseInsensitive,
                                         range: start..<text.endIndex, locale: .current) {
                if let converted = Range(range, in: attributed) {
                    attributed[converted].backgroundColor = AppTheme.accent.opacity(0.25)
                }
                start = range.upperBound
            }
        }
        return Text(attributed)
    }

    // MARK: - Details and copying

    private func exchangeDetails(_ record: VoiceHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exchange details").font(.system(size: 16, weight: .medium))
            metadataRow("Input ID", value: record.id.uuidString, key: "input-\(record.id)")
            if let turn = record.interaction.nativeTurnID {
                metadataRow("Turn ID", value: turn, key: "turn-\(record.id)")
            }
            Text("\(record.renditions.count) spoken revisions · \(record.attempts.count) playback attempts")
                .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            DisclosureGroup("Diagnostics · \(record.events.count)") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(record.events) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(eventTitle(event.kind))
                                Text(event.at.formatted(date: .omitted, time: .standard)).foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                .frame(maxHeight: 220)
            }
            .font(.system(size: 12)).disclosureGroupStyle(EmberDisclosureGroupStyle())
        }
        .padding(18).frame(width: 340)
    }

    private func copyIconButton(copyKey: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        let copied = copiedConfirmation == copyKey
        return Button(action: action) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(copied ? AppTheme.modelActive : AppTheme.secondaryText)
        }
        .buttonStyle(EmberIconButtonStyle())
        .accessibilityLabel(accessibilityLabel).help(accessibilityLabel)
    }

    private func copy(_ text: String, key: String) {
        if let onCopy { onCopy(text) }
        else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        copiedConfirmation = key
    }

    private var sessionDays: [Date] {
        Array(Set(visibleSessions.map { Calendar.current.startOfDay(for: $0.lastActiveDate) })).sorted(by: >)
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func eventTitle(_ kind: VoiceHistoryEventKind) -> String {
        switch kind {
        case .promptOpened: "Interaction started"
        case .renditionPrepared: "Spoken response prepared"
        case .stopObserved: "Host completion observed"
        case .autoAdmitted: "Automatic speech queued"
        case .manualAdmitted: "Replay requested"
        case .suppressed: "Automatic speech stopped by user"
        case .superseded: "Newer work replaced this response"
        case .playbackStarted: "Playback started"
        case .playbackCompleted: "Playback finished"
        case .playbackFailed: "Playback failed"
        case .playbackCancelled: "Playback stopped"
        case .interrupted: "Connection or interaction interrupted"
        case .expired: "Speech expired from queue"
        case .migrated: "Retained response imported from earlier history"
        }
    }
}
