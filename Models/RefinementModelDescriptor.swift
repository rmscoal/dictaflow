import Foundation

enum RefinementModelDescriptor: String, CaseIterable, Codable, Hashable, Sendable, LocalModelDescriptor {
    case qwen3Small
    case qwen35TwoB
    case qwen35FourB
    case qwen3FourB2507
    case llama32ThreeB
    case gemma4E2B
    case phi4Mini

    // Retained for storage cleanup and decoding older preferences.
    case qwen25HalfB
    case qwen25OneAndHalfB
    case qwen25ThreeB
    case smolLM2OnePointSevenB

    nonisolated static let allCases: [RefinementModelDescriptor] = [.qwen35TwoB, .qwen35FourB, .qwen3FourB2507, .qwen3Small, .llama32ThreeB, .gemma4E2B, .phi4Mini]
    nonisolated static let storedModels: [RefinementModelDescriptor] = allCases + [.qwen25HalfB, .qwen25OneAndHalfB, .qwen25ThreeB, .smolLM2OnePointSevenB]
    nonisolated static let recommendedDefault: RefinementModelDescriptor = .qwen3Small
    nonisolated static let bestQualityDefault: RefinementModelDescriptor = .qwen3Small

    nonisolated var provider: RefinementProvider {
        switch self {
        case .llama32ThreeB: .meta
        case .gemma4E2B: .google
        case .phi4Mini: .microsoft
        default: .qwen
        }
    }

    nonisolated var quantization: String { self == .gemma4E2B ? "Q4_0 · QAT" : "Q4_K_M" }

    nonisolated var modelIdentifier: String {
        "refinement.\(rawValue)"
    }

    nonisolated var displayName: String {
        switch self {
        case .qwen35TwoB: return "Qwen3.5 2B"
        case .qwen35FourB: return "Qwen3.5 4B"
        case .qwen3FourB2507: return "Qwen3-4B-Instruct-2507"
        case .llama32ThreeB: return "Llama 3.2 3B Instruct"
        case .gemma4E2B: return "Gemma 4 E2B IT QAT"
        case .phi4Mini: return "Phi-4-mini Instruct"

        case .qwen3Small:
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
        case .qwen35TwoB: return "Qwen3.5-2B-Q4_K_M.gguf"
        case .qwen35FourB: return "Qwen3.5-4B-Q4_K_M.gguf"
        case .qwen3FourB2507: return "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        case .llama32ThreeB: return "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
        case .gemma4E2B: return "gemma-4-E2B_q4_0-it.gguf"
        case .phi4Mini: return "Phi-4-mini-instruct-Q4_K_M.gguf"

        case .qwen3Small:
            return "Qwen3-0.6B-Q4_K_M.gguf"
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
        case .qwen35TwoB: return URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf")!
        case .qwen35FourB: return URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf")!
        case .qwen3FourB2507: return URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!
        case .llama32ThreeB: return URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/5ab33fa94d1d04e903623ae72c95d1696f09f9e8/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!
        case .gemma4E2B: return URL(string: "https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/675cff42a74c774d6cb76f76d8eacb49b48c9b93/gemma-4-E2B_q4_0-it.gguf")!
        case .phi4Mini: return URL(string: "https://huggingface.co/unsloth/Phi-4-mini-instruct-GGUF/resolve/78eb92a46fc37e6b524df991ed9aca9bc6aa7b80/Phi-4-mini-instruct-Q4_K_M.gguf")!

        case .qwen3Small:
            return URL(string: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/50968a4468ef4233ed78cd7c3de230dd1d61a56b/\(filename)")!
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
        case .qwen35TwoB: return .sha256("aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223")
        case .qwen35FourB: return .sha256("00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4")
        case .qwen3FourB2507: return .sha256("3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597")
        case .llama32ThreeB: return .sha256("6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff")
        case .gemma4E2B: return .sha256("fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634")
        case .phi4Mini: return .sha256("88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a")

        case .qwen3Small:
            return .sha256("ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a")
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
        case .qwen35TwoB: return 1280835840
        case .qwen35FourB: return 2740937888
        case .qwen3FourB2507: return 2497281120
        case .llama32ThreeB: return 2019377696
        case .gemma4E2B: return 3349516256
        case .phi4Mini: return 2491874272

        case .qwen3Small:
            return 396_705_472
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
        case .qwen35TwoB: return "1.28 GB"
        case .qwen35FourB: return "2.74 GB"
        case .qwen3FourB2507: return "2.50 GB"
        case .llama32ThreeB: return "2.02 GB"
        case .gemma4E2B: return "3.35 GB"
        case .phi4Mini: return "2.49 GB"

        case .qwen3Small:
            return "397 MB"
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
        case .qwen35TwoB: return 8
        case .qwen35FourB: return 16
        case .qwen3FourB2507: return 16
        case .llama32ThreeB: return 8
        case .gemma4E2B: return 16
        case .phi4Mini: return 16

        case .qwen3Small:
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
        case .qwen35TwoB: return "Est. 2–3.5 GB RAM"
        case .qwen35FourB: return "Est. 3.5–5 GB RAM"
        case .qwen3FourB2507: return "Est. 3.5–5.5 GB RAM"
        case .llama32ThreeB: return "Est. 3–4.5 GB RAM"
        case .gemma4E2B: return "Est. 4–6 GB RAM"
        case .phi4Mini: return "Est. 3.5–5.5 GB RAM"

        case .qwen3Small:
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
        case .qwen35TwoB: return 20
        case .qwen35FourB: return 30
        case .qwen3FourB2507: return 30
        case .llama32ThreeB: return 25
        case .gemma4E2B: return 25
        case .phi4Mini: return 25

        case .qwen3Small:
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
        case .qwen35TwoB: return "Local text refinement"
        case .qwen35FourB: return "Local text refinement"
        case .qwen3FourB2507: return "Local text refinement"
        case .llama32ThreeB: return "Local text refinement"
        case .gemma4E2B: return "Local text refinement"
        case .phi4Mini: return "Local text refinement"

        case .qwen3Small:
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
