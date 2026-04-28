import Foundation

enum TranscriptionPipelineState: Equatable {
    case idle
    case preparingModel(WhisperModelDescriptor)
    case downloadingModel(WhisperModelDescriptor, progress: Double?)
    case transcribing(WhisperModelDescriptor)
    case preparingRefinementModel(RefinementModelDescriptor)
    case downloadingRefinementModel(RefinementModelDescriptor, progress: Double?)
    case refining(RefinementModelDescriptor)

    var isTranscribing: Bool {
        if case .transcribing = self {
            return true
        }

        return false
    }

    var isPreparingModel: Bool {
        switch self {
        case .preparingModel, .downloadingModel, .preparingRefinementModel, .downloadingRefinementModel:
            return true
        case .idle, .transcribing, .refining:
            return false
        }
    }

    var isRefining: Bool {
        if case .refining = self {
            return true
        }

        return false
    }

    var isBusy: Bool {
        switch self {
        case .idle:
            return false
        case .preparingModel, .downloadingModel, .transcribing, .preparingRefinementModel, .downloadingRefinementModel, .refining:
            return true
        }
    }
}
