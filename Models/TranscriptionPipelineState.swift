import Foundation

enum TranscriptionPipelineState: Equatable {
    case idle
    case transcribing(WhisperModelDescriptor)
    case transcribingLiquid
    case refining(RefinementModelDescriptor)

    var isTranscribing: Bool {
        if case .transcribing = self {
            return true
        }
        if case .transcribingLiquid = self { return true }

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
        case .transcribing, .transcribingLiquid, .refining:
            return true
        }
    }
}
