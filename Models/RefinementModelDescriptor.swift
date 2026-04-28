import Foundation

enum RefinementModelDescriptor: String, CaseIterable, Codable, Hashable, Sendable, LocalModelDescriptor {
    case qwen25HalfB
    case qwen25OneAndHalfB
    case smolLM2OnePointSevenB

    nonisolated static let recommendedDefault: RefinementModelDescriptor = .qwen25OneAndHalfB

    nonisolated var modelIdentifier: String {
        "refinement.\(rawValue)"
    }

    nonisolated var displayName: String {
        switch self {
        case .qwen25HalfB:
            return "Qwen2.5 0.5B"
        case .qwen25OneAndHalfB:
            return "Qwen2.5 1.5B"
        case .smolLM2OnePointSevenB:
            return "SmolLM2 1.7B"
        }
    }

    nonisolated var pickerTitle: String {
        if self == Self.recommendedDefault {
            return "\(displayName) (Recommended)"
        }

        return displayName
    }

    nonisolated var filename: String {
        switch self {
        case .qwen25HalfB:
            return "qwen2.5-0.5b-instruct-q4_k_m.gguf"
        case .qwen25OneAndHalfB:
            return "qwen2.5-1.5b-instruct-q4_k_m.gguf"
        case .smolLM2OnePointSevenB:
            return "smollm2-1.7b-instruct-q4_k_m.gguf"
        }
    }

    nonisolated var downloadURL: URL {
        switch self {
        case .qwen25HalfB:
            return URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/\(filename)")!
        case .qwen25OneAndHalfB:
            return URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/\(filename)")!
        case .smolLM2OnePointSevenB:
            return URL(string: "https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF/resolve/main/\(filename)")!
        }
    }

    nonisolated var checksum: ModelChecksum {
        switch self {
        case .qwen25HalfB:
            return .sha256("74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db")
        case .qwen25OneAndHalfB:
            return .sha256("6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e")
        case .smolLM2OnePointSevenB:
            return .sha256("decd2598bc2c8ed08c19adc3c8fdd461ee19ed5708679d1c54ef54a5a30d4f33")
        }
    }

    nonisolated var approximateDiskSizeDescription: String {
        switch self {
        case .qwen25HalfB:
            return "469 MB"
        case .qwen25OneAndHalfB:
            return "1.0 GB"
        case .smolLM2OnePointSevenB:
            return "1.0 GB"
        }
    }

    nonisolated var detailText: String {
        switch self {
        case .qwen25HalfB:
            return "Fastest and smallest option. Good for quick punctuation and structure cleanup."
        case .qwen25OneAndHalfB:
            return "Recommended quality default for tone-aware cleanup while staying practical on Mac."
        case .smolLM2OnePointSevenB:
            return "Alternative compact language model with strong rewriting-oriented training."
        }
    }
}
