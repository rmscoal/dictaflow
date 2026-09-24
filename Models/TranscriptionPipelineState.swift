import Foundation

enum TranscriptionPipelineState: Equatable {
    case idle
    case transcribing(WhisperModelDescriptor)
    case refining(RefinementModelDescriptor)

    var isTranscribing: Bool {
        if case .transcribing = self {
            return true
        }

        return false
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
        case .transcribing, .refining:
            return true
        }
    }
}
