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

## Silero Voice Activity Detection Model

- Bundled file: `Resources/ggml-silero-v6.2.0.bin` (885,098 bytes)
- Source: <https://huggingface.co/ggml-org/whisper-vad/tree/9ffd54a1e1ee413ddf265af9913beaf518d1639b>
- SHA-256: `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`
- Upstream: <https://github.com/snakers4/silero-vad/tree/v6.2>
- License: MIT, Copyright (c) 2020-present Silero Team
- License file: `Resources/ThirdParty/silero-vad-LICENSE`, included in both app builds
- Notes: Speech detection runs locally before Whisper transcription and
  translation. The model is bundled, checksum-verified before use, and does not
  require a separate download.

## Refinement Models

- Referenced from: `Models/RefinementModelDescriptor.swift`
- Qwen3 0.6B: <https://huggingface.co/Qwen/Qwen3-0.6B>, Apache-2.0
- Standard 4-bit GGUF: <https://huggingface.co/unsloth/Qwen3-0.6B-GGUF>
- Model artifacts are downloaded separately and verified against pinned checksums.
- Legacy Qwen2.5 and SmolLM2 descriptors remain only to read saved preferences and
  recognize existing downloads for storage cleanup. They are no longer offered
  for inference. Their upstream model licenses continue to apply to those files.
