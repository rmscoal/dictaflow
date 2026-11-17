import Foundation

nonisolated enum SpeechRecognitionProvider: String, Codable, CaseIterable, Identifiable {
    case whisper, liquid
    var id: String { rawValue }
    var title: String { self == .whisper ? "Whisper" : "Liquid LFM3-Audio" }
    /// Short provider name shown in the speech model picker pills.
    var compactTitle: String { self == .whisper ? "OpenAI" : "Liquid" }
    /// Asset name for the provider logo, mirroring RefinementProvider.iconName.
    var iconName: String { self == .whisper ? "provider-openai" : "provider-liquid" }
}
