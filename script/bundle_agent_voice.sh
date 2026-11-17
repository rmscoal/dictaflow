#!/usr/bin/env bash
set -euo pipefail
DESTINATION_DIR="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIGURATION=debug
if [ "${CONFIGURATION:-Debug}" = Release ]; then BUILD_CONFIGURATION=release; fi
env -u SDKROOT swift build --package-path "$ROOT_DIR/Packages/AgentVoice" \
  -c "$BUILD_CONFIGURATION" --arch arm64 --product dictaflow-mcp
BIN_DIR="$(env -u SDKROOT swift build --package-path "$ROOT_DIR/Packages/AgentVoice" -c "$BUILD_CONFIGURATION" --arch arm64 --show-bin-path)"
cp "$BIN_DIR/dictaflow-mcp" "$DESTINATION_DIR/dictaflow-mcp"
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  if [ "$SIGN_IDENTITY" != - ]; then
    SIGN_ARGS+=(--options runtime)
    if [ "${CONFIGURATION:-Debug}" = Release ]; then SIGN_ARGS+=(--timestamp); else SIGN_ARGS+=(--timestamp=none); fi
  fi
  codesign "${SIGN_ARGS[@]}" "$DESTINATION_DIR/dictaflow-mcp"
fi
bash "$ROOT_DIR/script/ensure_audio_runtime.sh" "$DESTINATION_DIR/AudioRuntime"
NOTICES_DIR="$(dirname "$DESTINATION_DIR")/Resources/ThirdParty"
mkdir -p "$NOTICES_DIR"
for checkout in "$ROOT_DIR/Packages/AgentVoice/.build/checkouts/"*; do
  if [ -f "$checkout/LICENSE" ]; then install -m 644 "$checkout/LICENSE" "$NOTICES_DIR/agent-voice-$(basename "$checkout")-LICENSE"; fi
  if [ -f "$checkout/LICENSE.md" ]; then install -m 644 "$checkout/LICENSE.md" "$NOTICES_DIR/agent-voice-$(basename "$checkout")-LICENSE.md"; fi
  if [ -f "$checkout/LICENSE.txt" ]; then install -m 644 "$checkout/LICENSE.txt" "$NOTICES_DIR/agent-voice-$(basename "$checkout")-LICENSE.txt"; fi
done
