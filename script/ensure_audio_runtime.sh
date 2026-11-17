#!/usr/bin/env bash
set -euo pipefail

# Kept separate from refinement's pinned runtime and dylibs.
DESTINATION_DIR="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="$ROOT_DIR/.build/liquid-runtime/b11960"
ARCHIVE="$CACHE_DIR/llama-b11960-bin-macos-arm64.tar.gz"
EXPECTED_SHA="58e5a5e1d7c2bf66cedd9c29e0323f3e570660a70a1e2156d32eed08f4cc1e3c"
mkdir -p "$CACHE_DIR" "$DESTINATION_DIR"
verify_archive() {
  printf '%s  %s\n' "$EXPECTED_SHA" "$1" | shasum -a 256 --check
}
if [ -f "$ARCHIVE" ] && ! verify_archive "$ARCHIVE"; then
  rm -f "$ARCHIVE"
fi
if [ ! -f "$ARCHIVE" ]; then
  PARTIAL="$(mktemp "$ARCHIVE.partial.XXXXXX")"
  trap 'rm -f "$PARTIAL"' EXIT
  curl --fail --location --retry 3 --output "$PARTIAL" \
    https://github.com/ggml-org/llama.cpp/releases/download/b11960/llama-b11960-bin-macos-arm64.tar.gz
  verify_archive "$PARTIAL"
  mv "$PARTIAL" "$ARCHIVE"
fi
EXTRACT_DIR="$(mktemp -d "$CACHE_DIR/extracted.XXXXXX")"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR"
SOURCE="$(find "$EXTRACT_DIR" -type f -name llama-server -print -quit)"
test -n "$SOURCE"
cp -p "$SOURCE" "$DESTINATION_DIR/llama-server"
for library in "$(dirname "$SOURCE")"/libggml*.dylib "$(dirname "$SOURCE")"/libllama.*.dylib "$(dirname "$SOURCE")"/libllama.dylib "$(dirname "$SOURCE")"/libllama-common*.dylib "$(dirname "$SOURCE")"/libllama-server-impl.dylib "$(dirname "$SOURCE")"/libmtmd*.dylib; do
  [ -e "$library" ] || continue
  cp -pR "$library" "$DESTINATION_DIR/"
done
chmod 755 "$DESTINATION_DIR/llama-server"
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  if [ "$SIGN_IDENTITY" != - ]; then
    SIGN_ARGS+=(--options runtime)
    if [ "${CONFIGURATION:-Debug}" = Release ]; then SIGN_ARGS+=(--timestamp); else SIGN_ARGS+=(--timestamp=none); fi
  fi
  for binary in "$DESTINATION_DIR"/*.dylib "$DESTINATION_DIR/llama-server"; do
    [ -f "$binary" ] || continue
    [ ! -L "$binary" ] || continue
    codesign "${SIGN_ARGS[@]}" "$binary"
  done
fi
