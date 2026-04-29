# Third-Party Notices

This file summarizes third-party materials that DictaFlow vendors or references.
It does not replace the upstream license texts.

## whisper.cpp

- Path: `Vendor/whisper.cpp`
- License: MIT
- Copyright: Copyright (c) 2023-2026 The ggml authors
- License file: `Vendor/whisper.cpp/LICENSE`

## Whisper Models

- Referenced from: `Models/WhisperModelDescriptor.swift`
- Source: <https://huggingface.co/ggerganov/whisper.cpp>
- License: MIT
- Notes: DictaFlow downloads these model files at runtime and stores them in the
  user's Application Support model cache.

## Refinement Models

- Referenced from: `Models/RefinementModelDescriptor.swift`
- Qwen2.5 0.5B Instruct GGUF: <https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF>
- Qwen2.5 1.5B Instruct GGUF: <https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF>
- Qwen2.5 3B Instruct GGUF: <https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF>
- SmolLM2 1.7B Instruct GGUF: <https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF>
- Licenses as listed by upstream on 2026-04-29:
  - Qwen2.5 0.5B Instruct GGUF: Apache-2.0
  - Qwen2.5 1.5B Instruct GGUF: Apache-2.0
  - Qwen2.5 3B Instruct GGUF: Qwen Research License
  - SmolLM2 1.7B Instruct GGUF: Apache-2.0
- Notes: DictaFlow downloads these model files at runtime. The Qwen2.5 3B model
  is not Apache-2.0; review the upstream Qwen Research License before enabling
  it in a commercial context.
