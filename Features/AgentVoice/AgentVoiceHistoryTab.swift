import AgentVoice
import SwiftUI

/// Third Agent Voice tab. Lists every retained voice response (the full
/// `drafts` list, not just the first five). DictaFlow keeps response text,
/// not audio history: Play generates speech from that text. States that
/// can no longer produce speech explain why instead of offering Play.
struct AgentVoiceHistoryTab: View {
    @ObservedObject var voice: AgentVoiceCoordinator
    @State private var searchQuery = ""
    @State private var stateFilter: AgentVoiceHistoryFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmberModuleHeading(title: "Responses")
            Text("Play generates speech from the saved text.")
                .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            HStack(spacing: 8) {
                if voice.isSpeaking {
                    Text("Speaking…")
                        .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                } else if voice.isGenerating {
                    Text("Generating…")
                        .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                } else if let error = voice.activeError {
                    Text(error.message)
                        .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 8)
                if voice.isSpeaking || voice.isGenerating {
                    Button("Stop") { voice.stopSpeech() }
                        .buttonStyle(EmberButtonStyle())
                        .accessibilityLabel("Stop agent speech")
                        .accessibilityIdentifier("agent-voice-history-stop")
                }
            }
            .padding(.bottom, 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Voice status: \(voice.status)\(voice.isSpeaking ? ". Speaking now." : "")")

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondaryText)
                    TextField("Search responses", text: $searchQuery)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .accessibilityLabel("Search responses")
                    Picker("State", selection: $stateFilter) {
                        ForEach(AgentVoiceHistoryFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().font(.system(size: 12))
                    .accessibilityLabel("Filter by state")
                }
                .padding(11).background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 10)).padding(14)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if filteredDrafts.isEmpty {
                            Text(searchQuery.isEmpty && stateFilter == .all ? "No voice responses yet." : "No matching responses.")
                                .font(.system(size: 13)).foregroundStyle(AppTheme.secondaryText).padding(20)
                        } else {
                            ForEach(filteredDrafts) { draft in
                                draftRow(draft)
                            }
                        }
                    }
                    .padding(.horizontal, 9).padding(.bottom, 14)
                }
            }
            .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(AppTheme.border, lineWidth: 1) }
        }
    }

    private var filteredDrafts: [VoiceDraft] {
        voice.drafts.filter { draft in
            let matchesQuery = searchQuery.isEmpty ||
                draft.text.localizedCaseInsensitiveContains(searchQuery)
            let matchesFilter: Bool = {
                switch stateFilter {
                case .all: return true
                case .playable: return Self.isPlayable(draft.state)
                case .active: return !draft.state.isTerminal
                case .unavailable: return draft.state.isTerminal && !Self.isPlayable(draft.state)
                }
            }()
            return matchesQuery && matchesFilter
        }
    }

    private func draftRow(_ draft: VoiceDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                Spacer(minLength: 8)
                if let badge = Self.statusBadge(draft.state) {
                    Text(badge)
                        .font(.system(size: 11))
                        .foregroundStyle(draft.state == .failed ? AppTheme.errorText : AppTheme.modelActive)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            Text(draft.text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if Self.isPlayable(draft.state) {
                    Button(Self.playTitle(draft.state)) { voice.speak(draft) }
                        .buttonStyle(EmberButtonStyle(primary: true))
                        .disabled(!voice.isModelReady || !voice.isEnabled)
                        .accessibilityLabel("\(Self.playTitle(draft.state)) response from \(draft.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    if !voice.isModelReady {
                        Text("Download the Liquid model in Models to play.")
                            .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    }
                } else {
                    Text(Self.unavailableReason(draft.state))
                        .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.controlFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Response from \(draft.createdAt.formatted(date: .abbreviated, time: .shortened)). \(Self.isPlayable(draft.state) ? "Playable." : Self.unavailableReason(draft.state))")
    }

    /// Only active work and actionable failures get a badge. All other
    /// terminal rows stay quiet instead of showing raw state names.
    private static func statusBadge(_ state: VoiceState) -> String? {
        switch state {
        case .queued, .synthesizing: "Generating"
        case .playing: "Playing"
        case .failed: "Failed"
        default: nil
        }
    }

    /// Mirrors VoiceStore.authorizeByUser eligibility: only states with
    /// retained text that the store can re-authorize offer Play.
    private static func isPlayable(_ state: VoiceState) -> Bool {
        [.prepared, .awaitingCompletion, .completed, .failed, .cancelled, .interrupted, .superseded].contains(state)
    }

    private static func playTitle(_ state: VoiceState) -> String {
        switch state {
        case .failed, .cancelled: "Retry"
        case .interrupted, .superseded: "Play again"
        default: "Play"
        }
    }

    private static func unavailableReason(_ state: VoiceState) -> String {
        switch state {
        case .open: "Waiting for the host's response."
        case .queued, .synthesizing, .playing: "In progress."
        case .expired: "Expired. This response is no longer available."
        case .skippedMissingDraft: "Nothing was saved to play."
        default: "Unavailable."
        }
    }
}

enum AgentVoiceHistoryFilter: String, CaseIterable, Identifiable {
    case all, playable, active, unavailable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .playable: "Ready to play"
        case .active: "In progress"
        case .unavailable: "Unavailable"
        }
    }
}
