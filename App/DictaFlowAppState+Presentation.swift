import Foundation

struct ModelDownloadActivity: Equatable {
    enum Target: Equatable {
        case speech(WhisperModelDescriptor)
        case encoder(WhisperModelDescriptor)
        case refinement(RefinementModelDescriptor)
    }
    let target: Target
    /// Short model name for compact rows, without any status text.
    let name: String
    let title: String
    let progress: Double?
    let statusText: String
    let hasFailed: Bool

    var id: String {
        switch target {
        case .speech(let model): model.modelIdentifier
        case .encoder(let model): model.encoderModelIdentifier
        case .refinement(let model): model.modelIdentifier
        }
    }
}

/// Terminal download outcome shown as an in-app notification card.
/// It survives while the app is inactive or its window is closed, then
/// dismisses shortly after the user returns to the main window.
struct DownloadCompletionNotice: Equatable {
    enum Kind: Equatable {
        case completed
        case failed
    }
    let id = UUID()
    let activity: ModelDownloadActivity
    let kind: Kind
    let message: String

    var title: String {
        kind == .completed ? "Download complete" : "Download failed"
    }
}

extension DictaFlowAppState {
    /// Downloads in progress only, in a stable display order.
    /// Finished, failed, and cancelled downloads are not included.
    var activeDownloadActivities: [ModelDownloadActivity] {
        var activities: [ModelDownloadActivity] = []
        for model in WhisperModelDescriptor.allCases {
            if isDownloadingWhisperModel(model) {
                activities.append(ModelDownloadActivity(
                    target: .speech(model),
                    name: "Whisper \(model.displayName)",
                    title: "\(model.displayName) · \(whisperDownloadStatusText(for: model))",
                    progress: whisperDownloadProgress(for: model),
                    statusText: whisperDownloadStatusText(for: model),
                    hasFailed: false
                ))
            }
            if isDownloadingWhisperEncoder(model) {
                activities.append(ModelDownloadActivity(
                    target: .encoder(model),
                    name: "Whisper \(model.displayName) encoder",
                    title: "\(model.displayName) encoder · \(whisperEncoderDownloadStatusText(for: model))",
                    progress: whisperEncoderDownloadProgress(for: model),
                    statusText: whisperEncoderDownloadStatusText(for: model),
                    hasFailed: false
                ))
            }
        }
        for model in RefinementModelDescriptor.allCases where isDownloadingRefinementModel(model) {
            activities.append(ModelDownloadActivity(
                target: .refinement(model),
                name: model.displayName,
                title: "\(model.displayName) · \(refinementDownloadStatusText(for: model))",
                progress: refinementDownloadProgress(for: model),
                statusText: refinementDownloadStatusText(for: model),
                hasFailed: false
            ))
        }
        return activities
    }

    var modelDownloadActivity: ModelDownloadActivity? {
        for model in WhisperModelDescriptor.allCases {
            if whisperDownloadError(for: model) != nil {
                return ModelDownloadActivity(target: .speech(model), name: "Whisper \(model.displayName)", title: "\(model.displayName) download failed. Review download.", progress: nil, statusText: "", hasFailed: true)
            }
            if whisperEncoderDownloadError(for: model) != nil {
                return ModelDownloadActivity(target: .encoder(model), name: "Whisper \(model.displayName) encoder", title: "\(model.displayName) encoder download failed. Review download.", progress: nil, statusText: "", hasFailed: true)
            }
        }
        for model in RefinementModelDescriptor.allCases where refinementDownloadError(for: model) != nil {
            return ModelDownloadActivity(target: .refinement(model), name: model.displayName, title: "\(model.displayName) download failed. Review download.", progress: nil, statusText: "", hasFailed: true)
        }
        return activeDownloadActivities.first
    }

    func openDownloadActivity(_ activity: ModelDownloadActivity) {
        switch activity.target {
        case .speech(let model), .encoder(let model): showSpeechModels(focusing: model)
        case .refinement(let model): showRefinementModels(focusing: model)
        }
    }

    func cancelDownloadActivity(_ activity: ModelDownloadActivity) {
        switch activity.target {
        case .speech(let model): cancelWhisperModelDownload(model)
        case .encoder(let model): cancelWhisperEncoderDownload(model)
        case .refinement(let model): cancelRefinementModelDownload(model)
        }
    }

    func cancelAllDownloadActivities() {
        for activity in activeDownloadActivities {
            cancelDownloadActivity(activity)
        }
    }
}
