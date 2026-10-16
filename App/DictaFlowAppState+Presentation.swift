import Foundation

struct ModelDownloadActivity {
    enum Target {
        case speech(WhisperModelDescriptor)
        case encoder(WhisperModelDescriptor)
        case refinement(RefinementModelDescriptor)
    }
    let target: Target
    let title: String
    let hasFailed: Bool
}

extension DictaFlowAppState {
    var modelDownloadActivity: ModelDownloadActivity? {
        for model in WhisperModelDescriptor.allCases {
            if whisperDownloadError(for: model) != nil {
                return ModelDownloadActivity(target: .speech(model), title: "\(model.displayName) download failed. Review download.", hasFailed: true)
            }
            if whisperEncoderDownloadError(for: model) != nil {
                return ModelDownloadActivity(target: .encoder(model), title: "\(model.displayName) encoder download failed. Review download.", hasFailed: true)
            }
        }
        for model in RefinementModelDescriptor.allCases where refinementDownloadError(for: model) != nil {
            return ModelDownloadActivity(target: .refinement(model), title: "\(model.displayName) download failed. Review download.", hasFailed: true)
        }
        for model in WhisperModelDescriptor.allCases {
            if isDownloadingWhisperModel(model) {
                return ModelDownloadActivity(target: .speech(model), title: "\(model.displayName) · \(whisperDownloadStatusText(for: model))", hasFailed: false)
            }
            if isDownloadingWhisperEncoder(model) {
                return ModelDownloadActivity(target: .encoder(model), title: "\(model.displayName) encoder · \(whisperEncoderDownloadStatusText(for: model))", hasFailed: false)
            }
        }
        for model in RefinementModelDescriptor.allCases where isDownloadingRefinementModel(model) {
            return ModelDownloadActivity(target: .refinement(model), title: "\(model.displayName) · \(refinementDownloadStatusText(for: model))", hasFailed: false)
        }
        return nil
    }

    func openDownloadActivity(_ activity: ModelDownloadActivity) {
        switch activity.target {
        case .speech(let model), .encoder(let model): showSpeechModels(focusing: model)
        case .refinement(let model): showRefinementModels(focusing: model)
        }
    }
}
