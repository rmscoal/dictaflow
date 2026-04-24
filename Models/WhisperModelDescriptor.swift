import Foundation

enum WhisperModelDescriptor: String, CaseIterable, Codable, Hashable {
    case tiny
    case base
    case small
    case medium

    static let recommendedDefault: WhisperModelDescriptor = .small

    var displayName: String {
        switch self {
        case .tiny:
            return "Tiny"
        case .base:
            return "Base"
        case .small:
            return "Small"
        case .medium:
            return "Medium"
        }
    }

    var filename: String {
        "ggml-\(rawValue).bin"
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    var sha1Checksum: String {
        switch self {
        case .tiny:
            return "bd577a113a864445d4c299885e0cb97d4ba92b5f"
        case .base:
            return "465707469ff3a37a2b9b8d8f89f2f99de7299dac"
        case .small:
            return "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
        case .medium:
            return "fd9727b6e1217c2f614f9b698455c4ffd82463b4"
        }
    }

    var approximateDiskSizeDescription: String {
        switch self {
        case .tiny:
            return "75 MB"
        case .base:
            return "142 MB"
        case .small:
            return "466 MB"
        case .medium:
            return "1.5 GB"
        }
    }

    var detailText: String {
        switch self {
        case .tiny:
            return "Fastest startup with the lightest footprint. Best for quick notes and lower-end Macs."
        case .base:
            return "Balanced for everyday dictation with better accuracy than Tiny."
        case .small:
            return "Recommended default with strong quality for most general-purpose dictation."
        case .medium:
            return "Highest quality in V1, but noticeably heavier on CPU, memory, and disk."
        }
    }
}
