#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/DictaFlow.dmg" >&2
  exit 2
fi

DMG_PATH="$1"

if [ ! -f "$DMG_PATH" ]; then
  echo "error: DMG not found: $DMG_PATH" >&2
  exit 1
fi

MOUNT_OUTPUT="$(hdiutil attach "$DMG_PATH" -readonly -nobrowse)"
MOUNT_POINT="$(printf "%s\n" "$MOUNT_OUTPUT" | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/")); exit}')"

cleanup() {
  if [ -n "${MOUNT_POINT:-}" ]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

APP_PATH="$(find "$MOUNT_POINT" -maxdepth 1 -name '*.app' -type d | head -1)"
if [ -z "$APP_PATH" ]; then
  echo "error: no app bundle found in $DMG_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv --entitlements - "$APP_PATH"

LLAMA_SERVER_PATH="$APP_PATH/Contents/MacOS/llama-server"
if [ ! -x "$LLAMA_SERVER_PATH" ]; then
  echo "error: bundled llama-server is missing or not executable at $LLAMA_SERVER_PATH" >&2
  exit 1
fi

codesign --verify --strict --verbose=2 "$LLAMA_SERVER_PATH"
codesign -dvvv "$LLAMA_SERVER_PATH"
"$LLAMA_SERVER_PATH" --version

if [ "${REQUIRE_NOTARIZATION:-0}" = "1" ]; then
  xcrun stapler validate "$DMG_PATH"
  spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
  spctl -a -vv "$APP_PATH"
else
  echo "Skipping notarization checks. Set REQUIRE_NOTARIZATION=1 for release verification."
fi

echo "Verified $DMG_PATH"
