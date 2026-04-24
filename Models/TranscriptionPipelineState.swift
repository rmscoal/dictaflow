import Foundation

enum TranscriptionPipelineState: Equatable {
    case idle
    case preparingModel(WhisperModelDescriptor)
    case downloadingModel(WhisperModelDescriptor, progress: Double?)
    case transcribing(WhisperModelDescriptor)

    var isTranscribing: Bool {
        if case .transcribing = self {
            return true
        }

        return false
    }

    var isPreparingModel: Bool {
        switch self {
        case .preparingModel, .downloadingModel:
            return true
        case .idle, .transcribing:
            return false
        }
    }
}
