import Foundation

/// A pinned, verified local bundle. The runtime never downloads files itself.
nonisolated struct MLXRefinementModelFile: LocalModelDescriptor {
    let filename: String
    let sha256: String
    let sizeBytes: Int64

    nonisolated var modelIdentifier: String { "refinement.qwen3SmallMLX.\(filename)" }
    nonisolated var displayName: String { "Qwen3 0.6B (MLX)" }
    nonisolated var downloadURL: URL {
        URL(string: "https://huggingface.co/mlx-community/Qwen3-0.6B-4bit/resolve/73e3e38d981303bc594367cd910ea6eb48349da8/\(filename)")!
    }
    nonisolated var checksum: ModelChecksum { .sha256(sha256) }
    nonisolated var maximumDownloadSizeBytes: Int64 { sizeBytes + 1_000_000 }

    nonisolated static let files: [MLXRefinementModelFile] = [
        .init(filename: "model.safetensors", sha256: "392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2", sizeBytes: 335_450_584),
        .init(filename: "config.json", sha256: "15d3ac26c043ae477273ed5802ee0f0b33bb14f18c9d3dd70910c02d906e3f1f", sizeBytes: 937),
        .init(filename: "tokenizer.json", sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4", sizeBytes: 11_422_654),
        .init(filename: "tokenizer_config.json", sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0", sizeBytes: 9_706),
        .init(filename: "special_tokens_map.json", sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd", sizeBytes: 613),
        .init(filename: "added_tokens.json", sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680", sizeBytes: 707),
        .init(filename: "model.safetensors.index.json", sha256: "7b294141456f6904936db03c00bca50fb5f6198f652fe8483f9cd2a1018accfb", sizeBytes: 49_731)
    ]
}
