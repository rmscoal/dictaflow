import Foundation

enum RefinementModelDescriptor: String, CaseIterable, Codable, Hashable, Sendable, LocalModelDescriptor {
    case qwen3Small
    case qwen3SmallMLX

    // Retained for storage cleanup and decoding older preferences.
    case qwen25HalfB
    case qwen25OneAndHalfB
    case qwen25ThreeB
    case smolLM2OnePointSevenB

    nonisolated static let allCases: [RefinementModelDescriptor] = [.qwen3Small, .qwen3SmallMLX]
    nonisolated static let storedModels: [RefinementModelDescriptor] = allCases + [.qwen25HalfB, .qwen25OneAndHalfB, .qwen25ThreeB, .smolLM2OnePointSevenB]
    nonisolated var usesMLX: Bool { self == .qwen3SmallMLX }
    nonisolated static let recommendedDefault: RefinementModelDescriptor = .qwen3Small
    nonisolated static let bestQualityDefault: RefinementModelDescriptor = .qwen3Small

    nonisolated var modelIdentifier: String {
        "refinement.\(rawValue)"
    }

    nonisolated var displayName: String {
        switch self {
        case .qwen3Small, .qwen3SmallMLX:
            return "Qwen3 0.6B"
        case .qwen25HalfB:
            return "Qwen2.5 0.5B"
        case .qwen25OneAndHalfB:
            return "Qwen2.5 1.5B"
        case .qwen25ThreeB:
            return "Qwen2.5 3B"
        case .smolLM2OnePointSevenB:
            return "SmolLM2 1.7B"
        }
    }

    nonisolated var pickerTitle: String {
        return displayName
    }

    nonisolated var filename: String {
        switch self {
        case .qwen3Small:
            return "Qwen3-0.6B-Q4_K_M.gguf"
        case .qwen3SmallMLX:
            return "qwen3-0.6b-mlx-4bit"
        case .qwen25HalfB:
            return "qwen2.5-0.5b-instruct-q4_k_m.gguf"
        case .qwen25OneAndHalfB:
            return "qwen2.5-1.5b-instruct-q4_k_m.gguf"
        case .qwen25ThreeB:
            return "qwen2.5-3b-instruct-q4_k_m.gguf"
        case .smolLM2OnePointSevenB:
            return "smollm2-1.7b-instruct-q4_k_m.gguf"
        }
    }

    nonisolated var downloadURL: URL {
        switch self {
        case .qwen3Small:
            return URL(string: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/50968a4468ef4233ed78cd7c3de230dd1d61a56b/\(filename)")!
        case .qwen3SmallMLX:
            return MLXRefinementModelFile.files[0].downloadURL
        case .qwen25HalfB:
            return URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/\(filename)")!
        case .qwen25OneAndHalfB:
            return URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/\(filename)")!
        case .qwen25ThreeB:
            return URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/\(filename)")!
        case .smolLM2OnePointSevenB:
            return URL(string: "https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF/resolve/main/\(filename)")!
        }
    }

    nonisolated var checksum: ModelChecksum {
        switch self {
        case .qwen3Small:
            return .sha256("ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a")
        case .qwen3SmallMLX:
            return MLXRefinementModelFile.files[0].checksum
        case .qwen25HalfB:
            return .sha256("74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db")
        case .qwen25OneAndHalfB:
            return .sha256("6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e")
        case .qwen25ThreeB:
            return .sha256("626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d")
        case .smolLM2OnePointSevenB:
            return .sha256("decd2598bc2c8ed08c19adc3c8fdd461ee19ed5708679d1c54ef54a5a30d4f33")
        }
    }

    nonisolated var approximateDiskSizeBytes: Int64 {
        switch self {
        case .qwen3Small:
            return 396_705_472
        case .qwen3SmallMLX:
            return 346_935_225
        case .qwen25HalfB:
            return 469_000_000
        case .qwen25OneAndHalfB:
            return 1_000_000_000
        case .qwen25ThreeB:
            return 2_104_932_768
        case .smolLM2OnePointSevenB:
            return 1_000_000_000
        }
    }

    nonisolated var maximumDownloadSizeBytes: Int64 {
        approximateDiskSizeBytes + 250_000_000
    }

    nonisolated var approximateDiskSizeDescription: String {
        switch self {
        case .qwen3Small:
            return "397 MB"
        case .qwen3SmallMLX:
            return "347 MB"
        case .qwen25HalfB:
            return "469 MB"
        case .qwen25OneAndHalfB:
            return "1.0 GB"
        case .qwen25ThreeB:
            return "2.1 GB"
        case .smolLM2OnePointSevenB:
            return "1.0 GB"
        }
    }

    nonisolated var minimumMemoryGB: Int {
        switch self {
        case .qwen3Small, .qwen3SmallMLX:
            return 8
        case .qwen25HalfB:
            return 4
        case .qwen25OneAndHalfB, .smolLM2OnePointSevenB:
            return 8
        case .qwen25ThreeB:
            return 16
        }
    }

    nonisolated var recommendedMemoryGB: Int {
        minimumMemoryGB
    }

    nonisolated var estimatedRuntimeMemoryDescription: String {
        switch self {
        case .qwen3Small, .qwen3SmallMLX:
            return "Compact 4-bit model"
        case .qwen25HalfB:
            return "~1 GB RAM"
        case .qwen25OneAndHalfB:
            return "~2 GB RAM"
        case .qwen25ThreeB:
            return "~3-4 GB RAM"
        case .smolLM2OnePointSevenB:
            return "~2 GB RAM"
        }
    }

    nonisolated var qualityRank: Int {
        switch self {
        case .qwen3Small, .qwen3SmallMLX:
            return 10
        case .qwen25HalfB:
            return 10
        case .smolLM2OnePointSevenB:
            return 20
        case .qwen25OneAndHalfB:
            return 30
        case .qwen25ThreeB:
            return 40
        }
    }

    nonisolated var detailText: String {
        switch self {
        case .qwen3Small, .qwen3SmallMLX:
            return "Fast local cleanup for punctuation, wording, and self-corrections."
        case .qwen25HalfB:
            return "Fastest and smallest option. Good for quick punctuation and structure cleanup."
        case .qwen25OneAndHalfB:
            return "Recommended quality default for tone-aware cleanup while staying practical on Mac."
        case .qwen25ThreeB:
            return "Best quality option for stricter grammar, wording, and repeated-meaning cleanup."
        case .smolLM2OnePointSevenB:
            return "Alternative compact language model with strong rewriting-oriented training."
        }
    }

}
