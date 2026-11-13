import AgentVoice
import Foundation

/// One host turn inside a session: history records grouped by the host turn
/// id when the host publishes one, else one thread per input.
struct AgentVoiceThread: Identifiable {
    /// Session id plus the native turn id, or the input id when the host
    /// sent no turn id.
    let id: String
    let nativeTurnID: String?
    /// Oldest first, so a corrected turn reads top to bottom.
    var records: [VoiceHistoryRecord]
    var startDate: Date
    var lastActiveDate: Date
    var isLive: Bool

    /// First non-empty prompt in the thread, for the row subtitle.
    var promptSnippet: String? {
        records.lazy.compactMap { record in
            guard let prompt = record.interaction.promptText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty else { return nil }
            return prompt
        }.first
    }

    /// Host turn id when the host published one, else the single input id.
    /// Multi-input threads always carry a native turn id by construction.
    var threadIDDisplay: String {
        nativeTurnID ?? records.first?.interaction.id.uuidString ?? id
    }

    /// Headline pulled/speech state across the thread, newest record first.
    var speechStatusHeadline: String {
        let ordered = records.sorted { $0.interaction.createdAt > $1.interaction.createdAt }
        for record in ordered {
            let headline = AgentVoiceSpeechStatus.headline(for: record)
            if headline != AgentVoiceSpeechStatus.noResponse { return headline }
        }
        return ordered.first.map(AgentVoiceSpeechStatus.headline) ?? AgentVoiceSpeechStatus.noResponse
    }
}

/// Pulled/speech status for one interaction, derived from suppression, live
/// attempts, and retained renditions. Raw store events never feed the
/// headline; they are an append-only diagnostic log.
enum AgentVoiceSpeechStatus {
    static let noResponse = "No spoken response"

    static func headline(for record: VoiceHistoryRecord) -> String {
        if record.interaction.isSuppressed { return "Suppressed" }
        if let active = record.attempts.first(where: { !$0.state.isTerminal }) {
            switch active.state {
            case .playing: return "Playing"
            case .synthesizing, .queued: return "Generating speech"
            default: return "In progress"
            }
        }
        if record.interaction.currentRenditionID != nil ||
            !record.renditions.isEmpty { return "Ready to play" }
        return noResponse
    }

    static func isInProgress(_ record: VoiceHistoryRecord, renditionID: UUID) -> Bool {
        record.attempts.contains { $0.renditionID == renditionID && !$0.state.isTerminal }
    }
}

/// One host session: all threads that share a host plus session id.
struct AgentVoiceSessionGroup: Identifiable {
    /// Host plus session id. Host session ids are only unique per host.
    let id: String
    let host: String
    let sessionID: String
    let brand: AgentVoiceHostBrand
    /// Newest first.
    var threads: [AgentVoiceThread]
    var startDate: Date
    var lastActiveDate: Date
    var isLive: Bool

    var shortID: String { String(sessionID.prefix(8)) }

    var interactionCount: Int { threads.reduce(0) { $0 + $1.records.count } }

    var threadCountLabel: String { "\(threads.count) \(threads.count == 1 ? "thread" : "threads")" }

    /// Turns remain available for diagnostics, but reading a conversation
    /// follows input time across every turn, including corrected inputs.
    var records: [VoiceHistoryRecord] {
        threads.flatMap(\.records).sorted {
            if $0.interaction.createdAt != $1.interaction.createdAt {
                return $0.interaction.createdAt < $1.interaction.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var title: String {
        records.lazy.compactMap { record -> String? in
            guard let prompt = record.interaction.promptText else { return nil }
            let text = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.isEmpty ? nil : String(text.prefix(120))
        }.first ?? "Conversation with \(brand.displayName)"
    }

    var preview: String {
        guard let record = records.last else { return "No saved messages" }
        let rendition = record.renditions.first { $0.id == record.interaction.currentRenditionID }
            ?? record.renditions.max { $0.revision < $1.revision }
        let text = rendition?.text ?? record.interaction.promptText ?? "No spoken response saved"
        return String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
    }
}

enum AgentVoiceSessionGrouping {
    static let pageSize = 50

    /// Groups flat history records into sessions containing threads.
    /// Sessions sort by last activity, newest first.
    static func sessions(from records: [VoiceHistoryRecord], matching query: String = "") -> [AgentVoiceSessionGroup] {
        let bySession = Dictionary(grouping: records) {
            "\($0.interaction.session.host)\u{1F}\($0.interaction.session.sessionID)"
        }
        return bySession.map { key, sessionRecords in
            let session = sessionRecords[0].interaction.session
            let threads = threads(from: sessionRecords, sessionID: session.sessionID)
            let startDate = sessionRecords.map(\.interaction.createdAt).min() ?? Date()
            let lastActive = sessionRecords.map(lastActiveDate).max() ?? startDate
            return AgentVoiceSessionGroup(
                id: key,
                host: session.host,
                sessionID: session.sessionID,
                brand: AgentVoiceHostBrand.brand(forHostName: session.host),
                threads: threads,
                startDate: startDate,
                lastActiveDate: lastActive,
                isLive: threads.contains(where: \.isLive)
            )
        }
        // Search selects whole sessions. Counts, dates, the conversation,
        // and deletion scope must never become a subset of matching inputs.
        .filter { session in session.records.contains { matches($0, query: query) } }
        .sorted {
            if $0.lastActiveDate != $1.lastActiveDate { return $0.lastActiveDate > $1.lastActiveDate }
            return $0.id < $1.id
        }
    }

    /// Flat text filter kept from the per-input list, so search still matches
    /// host, session id, prompts, and rendition text.
    static func matches(_ record: VoiceHistoryRecord, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return record.interaction.session.host.localizedCaseInsensitiveContains(trimmed) ||
            record.interaction.session.sessionID.localizedCaseInsensitiveContains(trimmed) ||
            (record.interaction.promptText?.localizedCaseInsensitiveContains(trimmed) == true) ||
            record.renditions.contains { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    private static func threads(from records: [VoiceHistoryRecord], sessionID: String) -> [AgentVoiceThread] {
        let byThread = Dictionary(grouping: records) {
            "\(sessionID)#\($0.interaction.nativeTurnID ?? $0.interaction.id.uuidString)"
        }
        return byThread.map { key, threadRecords in
            let sorted = threadRecords.sorted { $0.interaction.createdAt < $1.interaction.createdAt }
            let startDate = sorted.first?.interaction.createdAt ?? Date()
            return AgentVoiceThread(
                id: key,
                nativeTurnID: sorted.first?.interaction.nativeTurnID,
                records: sorted,
                startDate: startDate,
                lastActiveDate: sorted.map(lastActiveDate).max() ?? startDate,
                isLive: sorted.contains(where: isLive)
            )
        }
        .sorted { $0.startDate > $1.startDate }
    }

    /// Latest activity across the interaction, its renditions, attempts, and
    /// events, so replay and Stop observations refresh the session time.
    private static func lastActiveDate(_ record: VoiceHistoryRecord) -> Date {
        let dates = [record.interaction.createdAt] +
            record.renditions.map(\.createdAt) +
            record.attempts.map(\.createdAt) +
            record.events.map(\.at)
        return dates.max() ?? record.interaction.createdAt
    }

    /// A thread is live while the host may still act on it, or while one of
    /// its attempts is still queued, generating, or playing.
    private static func isLive(_ record: VoiceHistoryRecord) -> Bool {
        !record.interaction.hostClosed || record.attempts.contains { !$0.state.isTerminal }
    }
}
