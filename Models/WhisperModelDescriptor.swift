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

    nonisolated var encoderModelIdentifier: String {
        "\(modelIdentifier).encoder"
    }

    nonisolated var encoderZipFilename: String {
        "ggml-\(rawValue)-encoder.mlmodelc.zip"
    }

    nonisolated var encoderDirectoryName: String {
        "ggml-\(rawValue)-encoder.mlmodelc"
    }

    nonisolated var encoderDisabledDirectoryName: String {
        "\(encoderDirectoryName).disabled"
    }

    nonisolated var encoderDownloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(encoderZipFilename)")!
    }

    nonisolated var encoderChecksum: ModelChecksum {
        switch self {
        case .tiny:
            return .sha256("c88cbd2648e1f5415092bcf5256add463a0f19943e6938f46e8d4ffdebd47739")
        case .base:
            return .sha256("7e6ab77041942572f239b5b602f8aaa1c3ed29d73e3d8f20abea03a773541089")
        case .small:
            return .sha256("de43fb9fed471e95c19e60ae67575c2bf09e8fb607016da171b06ddad313988b")
        case .medium:
            return .sha256("79b0b8d436d47d3f24dd3afc91f19447dd686a4f37521b2f6d9c30a642133fbd")
        case .largeV3Turbo:
            return .sha256("84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a")
        case .largeV3:
            return .sha256("47837be7594a29429ec08620043390c4d6d467f8bd362df09e9390ace76a55a4")
        }
    }

    nonisolated var encoderApproximateSizeBytes: Int64 {
        switch self {
        case .tiny:
            return 15_037_446
        case .base:
            return 37_922_638
        case .small:
            return 163_083_239
        case .medium:
            return 567_829_413
        case .largeV3Turbo:
            return 1_173_393_014
        case .largeV3:
            return 1_175_711_232
        }
    }

    nonisolated var encoderMaximumDownloadSizeBytes: Int64 {
        encoderApproximateSizeBytes + 250_000_000
    }

    nonisolated var encoderApproximateSizeDescription: String {
        switch self {
        case .tiny:
            return "15 MB"
        case .base:
            return "38 MB"
        case .small:
            return "163 MB"
        case .medium:
            return "568 MB"
        case .largeV3Turbo:
            return "1.2 GB"
        case .largeV3:
            return "1.2 GB"
        }
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
            return "Best balance of speed and quality. Near Large V3 accuracy at Medium size. Uses more battery per dictation than smaller models."
        case .largeV3:
            return "Highest accuracy for difficult audio, but the heaviest and slowest model. Uses the most battery per dictation."
        }
    }
}
