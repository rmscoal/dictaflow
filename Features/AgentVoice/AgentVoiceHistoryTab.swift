import AgentVoice
import SwiftUI

/// Retained interactions are independent of queue eligibility. Replay synthesizes
/// the chosen immutable rendition; it does not reopen the host's turn.
struct AgentVoiceHistoryTab: View {
    @ObservedObject var voice: AgentVoiceCoordinator
    @State private var searchQuery = ""
    @State private var pendingDeletion: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EmberModuleHeading(title: "Voice history")
            Text("Interactions are kept for up to 30 days, limited to 500. Replay generates speech from saved text.")
                .font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            HStack {
                Text(voice.status).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                Spacer()
                if voice.isSpeaking || voice.isGenerating {
                    Button("Stop") { voice.stopSpeech() }
                        .buttonStyle(EmberButtonStyle())
                        .accessibilityIdentifier("agent-voice-history-stop")
                }
            }
            TextField("Search sessions and responses", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search voice history")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if records.isEmpty {
                        Text(searchQuery.isEmpty ? "No voice interactions yet." : "No matching interactions.")
                            .foregroundStyle(AppTheme.secondaryText).padding(20)
                    }
                    ForEach(records) { record in interactionRow(record) }
                }
            }
        }
        .confirmationDialog("Delete this voice interaction and its saved responses?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Delete interaction", role: .destructive) {
                if let id = pendingDeletion { voice.deleteInteraction(id) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        }
    }

    private var records: [VoiceHistoryRecord] {
        voice.history.filter { record in
            searchQuery.isEmpty ||
            record.interaction.session.host.localizedCaseInsensitiveContains(searchQuery) ||
            record.interaction.session.sessionID.localizedCaseInsensitiveContains(searchQuery) ||
            (record.interaction.promptText?.localizedCaseInsensitiveContains(searchQuery) == true) ||
            record.renditions.contains { $0.text.localizedCaseInsensitiveContains(searchQuery) }
        }
    }

    private func interactionRow(_ record: VoiceHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(record.interaction.session.host).font(.system(size: 13, weight: .medium))
                Text(String(record.interaction.session.sessionID.prefix(8)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(AppTheme.secondaryText)
                Spacer()
                Text(record.interaction.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            }
            if let prompt = record.interaction.promptText, !prompt.isEmpty {
                Text(prompt).font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(3).textSelection(.enabled)
            }
            if record.interaction.isSuppressed {
                Label("Automatic speech stopped for this interaction", systemImage: "speaker.slash")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            }
            if let current = record.renditions.first(where: { $0.id == record.interaction.currentRenditionID }) {
                renditionRow(current, attempts: record.attempts)
            } else {
                Text("No spoken response retained.").font(.system(size: 12)).foregroundStyle(AppTheme.secondaryText)
            }
            DisclosureGroup("Activity · \(record.events.count) events") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(record.renditions.filter { $0.id != record.interaction.currentRenditionID }) { rendition in
                        renditionRow(rendition, attempts: record.attempts)
                    }
                    ForEach(record.attempts) { attempt in
                        HStack(alignment: .top) {
                            Text(attempt.createdAt.formatted(date: .omitted, time: .standard))
                            Text("Revision \(attempt.revision) · \(attempt.kind == .automatic ? "Automatic" : attempt.kind == .manual ? "Replay" : "Earlier playback") · \(stateTitle(attempt.state))")
                        }
                        .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                        if let failure = attempt.failure {
                            Text(failure).font(.system(size: 11)).foregroundStyle(AppTheme.errorText)
                        }
                    }
                    ForEach(record.events) { event in
                        HStack(alignment: .top) {
                            Text(event.at.formatted(date: .omitted, time: .standard))
                            Text(eventTitle(event.kind))
                        }
                        .font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12))
            HStack {
                Spacer()
                Button("Delete…", role: .destructive) { pendingDeletion = record.id }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
        }
        .padding(14)
        .background(AppTheme.tileFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func renditionRow(_ rendition: VoiceRendition, attempts: [VoicePlaybackAttempt]) -> some View {
        let active = attempts.contains { $0.renditionID == rendition.id && !$0.state.isTerminal }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Revision \(rendition.revision)").font(.system(size: 11)).foregroundStyle(AppTheme.secondaryText)
            Text(rendition.text).font(.system(size: 13)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(active ? "In progress" : "Play") { voice.playRendition(rendition.id) }
                    .buttonStyle(EmberButtonStyle())
                    .disabled(active || !voice.isEnabled || !voice.isModelReady)
                    .accessibilityLabel("Play revision \(rendition.revision)")
            }
        }
    }

    private func stateTitle(_ state: VoiceState) -> String {
        switch state {
        case .open: "Waiting"
        case .prepared, .awaitingCompletion: "Prepared"
        case .queued: "Queued"
        case .synthesizing: "Generating"
        case .playing: "Playing"
        case .completed: "Finished"
        case .skippedMissingDraft: "No response"
        case .interrupted: "Interrupted"
        case .cancelled: "Stopped"
        case .expired: "Expired from queue"
        case .superseded: "Replaced"
        case .failed: "Failed"
        }
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
