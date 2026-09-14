import Foundation

enum WhisperModelDescriptor: String, CaseIterable, Codable, Hashable, Sendable, LocalModelDescriptor {
    case tiny
    case base
    case small
    case medium
    case largeV3Turbo = "large-v3-turbo"
    case largeV3 = "large-v3"

    static let recommendedDefault: WhisperModelDescriptor = .small

    nonisolated var modelIdentifier: String {
        "whisper.\(rawValue)"
    }

    nonisolated var displayName: String {
        switch self {
        case .tiny:
            return "Tiny"
        case .base:
            return "Base"
        case .small:
            return "Small"
        case .medium:
            return "Medium"
        case .largeV3Turbo:
            return "Large V3 Turbo"
        case .largeV3:
            return "Large V3"
        }
    }

    nonisolated var filename: String {
        "ggml-\(rawValue).bin"
    }

    nonisolated var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    nonisolated var sha1Checksum: String {
        switch self {
        case .tiny:
            return "bd577a113a864445d4c299885e0cb97d4ba92b5f"
        case .base:
            return "465707469ff3a37a2b9b8d8f89f2f99de7299dac"
        case .small:
            return "55356645c2b361a969dfd0ef2c5a50d530afd8d5"
        case .medium:
            return "fd9727b6e1217c2f614f9b698455c4ffd82463b4"
        case .largeV3Turbo:
            return "4af2b29d7ec73d781377bfd1758ca957a807e941"
        case .largeV3:
            return "ad82bf6a9043ceed055076d0fd39f5f186ff8062"
        }
    }

    nonisolated var checksum: ModelChecksum {
        .sha1(sha1Checksum)
    }

    nonisolated var approximateDiskSizeBytes: Int64 {
        switch self {
        case .tiny:
            return 75_000_000
        case .base:
            return 142_000_000
        case .small:
            return 466_000_000
        case .medium:
            return 1_500_000_000
        case .largeV3Turbo:
            return 1_500_000_000
        case .largeV3:
            return 2_900_000_000
        }
    }

    nonisolated var maximumDownloadSizeBytes: Int64 {
        approximateDiskSizeBytes + 250_000_000
    }

    nonisolated var approximateDiskSizeDescription: String {
        switch self {
        case .tiny:
            return "75 MB"
        case .base:
            return "142 MB"
        case .small:
            return "466 MB"
        case .medium:
            return "1.5 GB"
        case .largeV3Turbo:
            return "1.5 GB"
        case .largeV3:
            return "2.9 GB"
        }
    }

    nonisolated var detailText: String {
        switch self {
        case .tiny:
            return "Fastest startup with the lightest footprint. Best for quick notes and lower-end Macs."
        case .base:
            return "Balanced for everyday dictation with better accuracy than Tiny."
        case .small:
            return "Recommended default with strong quality for most general-purpose dictation."
        case .medium:
            return "Strong accuracy with reliable translation. Noticeably heavier on CPU, memory, and disk."
        case .largeV3Turbo:
            return "Best balance of speed and quality. Near Large V3 accuracy at Medium size."
        case .largeV3:
            return "Highest accuracy for difficult audio, but the heaviest and slowest model."
        }
    }
}
