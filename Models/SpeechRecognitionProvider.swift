import Foundation

nonisolated enum SpeechRecognitionProvider: String, Codable, CaseIterable, Identifiable {
    case whisper, liquid
    var id: String { rawValue }
    var title: String { self == .whisper ? "Whisper" : "Liquid LFM3-Audio" }
}
