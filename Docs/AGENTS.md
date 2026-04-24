# AGENTS.md

## DictaFlow

Build a native **macOS-only Swift app** for fully local voice dictation.

### Purpose
Record microphone audio, run **Whisper.cpp** locally for transcription/translation, then insert text into the active cursor field.

### Stack
- Swift
- SwiftUI + AppKit
- AVFoundation
- Accessibility APIs
- Whisper.cpp bridge

### Targets
- Dev: `DictaFlow Dev` / `com.dictaflow.dev`
- Release: `DictaFlow` / `com.dictaflow.app`

Never mix permission states between targets.

### Build Rules
Always test installed builds from `/Applications/`, never DerivedData.

### Permissions
- Ask Microphone first
- Ask Accessibility only for text insertion
- Recheck permissions every launch

### Insert Fallback
1. Direct accessibility insert  
2. Paste  
3. Simulated typing  
4. Copy popup

### Principles
Local-first, private, reliable, fast, native macOS UX.

### Never
No cloud inference, no silent failures, no temporary-path permission testing.
