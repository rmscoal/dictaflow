# Third-Party Notices

This file summarizes third-party materials that DictaFlow vendors or references.
It does not replace the upstream license texts.

## whisper.cpp

- Path: `Vendor/whisper.cpp`
- License: MIT
- Copyright: Copyright (c) 2023-2026 The ggml authors
- License file: `Vendor/whisper.cpp/LICENSE`

## llama.cpp

- Bundled binary: `llama-server` in public macOS app builds
- Source: <https://github.com/ggml-org/llama.cpp>
- Pinned release: `b9627`
- License: MIT
- Copyright: Copyright (c) 2023-2026 The ggml authors
- Notes: DictaFlow bundles `llama-server` so local transcript refinement can run
  without requiring users to install Homebrew, Ollama, or a separate llama.cpp
  runtime.

## Whisper Models

- Referenced from: `Models/WhisperModelDescriptor.swift`
- Source: <https://huggingface.co/ggerganov/whisper.cpp>
- License: MIT
- Notes: DictaFlow downloads these model files at runtime and stores them in the
  user's Application Support model cache.

## MLX Inference and Tokenizers

- MLX Swift: <https://github.com/ml-explore/mlx-swift>, MIT
- MLX Swift LM: <https://github.com/ml-explore/mlx-swift-lm>, MIT
- Swift Transformers: <https://github.com/huggingface/swift-transformers>, Apache-2.0
- Exact resolved dependency versions: `DictaFlow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Upstream licenses for these packages and their runtime dependencies are bundled
  under `Resources/ThirdParty`. Build-time macro tooling is not shipped in the app.

## Refinement Models

- Referenced from: `Models/RefinementModelDescriptor.swift` and `Models/MLXRefinementModelFile.swift`
- Qwen3 0.6B: <https://huggingface.co/Qwen/Qwen3-0.6B>, Apache-2.0
- Standard 4-bit GGUF: <https://huggingface.co/unsloth/Qwen3-0.6B-GGUF>
- Experimental 4-bit MLX: <https://huggingface.co/mlx-community/Qwen3-0.6B-4bit>
- Model artifacts are downloaded separately and verified against pinned checksums.
- Legacy Qwen2.5 and SmolLM2 descriptors remain only to read saved preferences and
  recognize existing downloads for storage cleanup. They are no longer offered
  for inference. Their upstream model licenses continue to apply to those files.
