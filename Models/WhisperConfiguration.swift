import Foundation

struct WhisperConfiguration: Codable, Equatable {
    var model: WhisperModelDescriptor
    var inputLanguage: WhisperInputLanguage
    var taskMode: WhisperTaskMode

    static let `default` = WhisperConfiguration(
        model: .recommendedDefault,
        inputLanguage: .automatic,
        taskMode: .translateToEnglish
    )
}
