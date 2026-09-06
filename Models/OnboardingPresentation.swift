import Foundation

enum OnboardingStep: Int, CaseIterable, Equatable {
    case welcome
    case permissions
    case offlineModel
    case shortcut
    case ready

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }
}

enum OnboardingMode: Equatable {
    case initialSetup
    case permissionRecovery
}

enum OnboardingPracticeResult: Equatable {
    case transcription(String)
    case noSpeech
}

struct OnboardingPresentation: Equatable {
    var mode: OnboardingMode
    var step: OnboardingStep

    static let initialSetup = OnboardingPresentation(
        mode: .initialSetup,
        step: .welcome
    )

    static let permissionRecovery = OnboardingPresentation(
        mode: .permissionRecovery,
        step: .permissions
    )
}
