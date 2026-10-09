import Foundation

nonisolated enum HistoryRetention: Int, CaseIterable, Identifiable {
    case off = 0
    case sevenDays = 7
    case fourteenDays = 14

    var id: Int { rawValue }
    var title: String { self == .off ? "Off" : "\(rawValue) days" }
}

nonisolated enum HistoryAttemptStatus: String {
    case running, succeeded, failed, interrupted, unprocessed
}

nonisolated struct HistoryCapture {
    let id: UUID
    let fileURL: URL
}

nonisolated struct HistoryEntry: Identifiable, Equatable {
    let id: UUID
    let capturedAt: Date
    let duration: TimeInterval
    let expiresAt: Date
    let preview: String
    let status: HistoryAttemptStatus
    let audioAvailable: Bool

    var title: String {
        let words = preview.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
        return words.isEmpty ? "Recording at \(capturedAt.formatted(date: .omitted, time: .shortened))" : words
    }
}

nonisolated struct HistoryTranscription: Identifiable {
    let id: UUID
    let startedAt: Date
    let status: HistoryAttemptStatus
    let configuration: WhisperConfiguration
    let result: WhisperTranscriptionResult?
    let errorMessage: String?
}

nonisolated struct HistoryRefinement: Identifiable {
    let id: UUID
    let transcriptionID: UUID
    let startedAt: Date
    let status: HistoryAttemptStatus
    let configuration: RefinementConfiguration
    let prompt: String
    let result: TranscriptRefinementResult?
    let errorMessage: String?
}

nonisolated struct HistoryDetail {
    let entry: HistoryEntry
    let transcriptions: [HistoryTranscription]
    let refinements: [HistoryRefinement]
}

nonisolated enum HistoryStoreError: LocalizedError {
    case unavailable
    case inUse
    case invalidRecording

    var errorDescription: String? {
        switch self {
        case .unavailable: "The recording is no longer available."
        case .inUse: "Stop playback or wait for processing before deleting this recording."
        case .invalidRecording: "The saved recording could not be read."
        }
    }
}
