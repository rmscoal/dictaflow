#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/DictaFlow.app/Contents/MacOS" >&2
  exit 2
fi

DESTINATION_DIR="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LLAMA_CPP_VERSION="${LLAMA_CPP_VERSION:-b9627}"
LLAMA_CPP_ARCH="${LLAMA_CPP_ARCH:-$(uname -m)}"

case "$LLAMA_CPP_ARCH" in
  arm64)
    ASSET_ARCH="arm64"
    ARCHIVE_SHA256="30461fcf06eca9249af69247704f48640987a159412b2c77aa02acbd4e2c1351"
    ;;
  x86_64)
    ASSET_ARCH="x64"
    ARCHIVE_SHA256="99b3e71c47d4bdce09687d7b96db74417038fc9b89f074d093a073179fcfb187"
    ;;
  *)
    echo "error: unsupported llama.cpp macOS architecture: $LLAMA_CPP_ARCH" >&2
    exit 1
    ;;
esac

ARCHIVE_NAME="llama-${LLAMA_CPP_VERSION}-bin-macos-${ASSET_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_CPP_VERSION}/${ARCHIVE_NAME}"
CACHE_DIR="$ROOT_DIR/.build/llama.cpp/${LLAMA_CPP_VERSION}/${ASSET_ARCH}"
ARCHIVE_PATH="$CACHE_DIR/$ARCHIVE_NAME"
EXTRACT_DIR="$CACHE_DIR/extracted"
RUNTIME_CACHE_DIR="$CACHE_DIR/runtime"
DESTINATION_PATH="$DESTINATION_DIR/llama-server"
CONTENTS_DIR="$(dirname "$DESTINATION_DIR")"
THIRD_PARTY_DIR="$CONTENTS_DIR/Resources/ThirdParty"

mkdir -p "$CACHE_DIR" "$DESTINATION_DIR"

if [ ! -x "$RUNTIME_CACHE_DIR/llama-server" ]; then
  if [ ! -f "$ARCHIVE_PATH" ]; then
    echo "Downloading $DOWNLOAD_URL"
    curl --fail --location --retry 3 --output "$ARCHIVE_PATH" "$DOWNLOAD_URL"
  fi

  printf "%s  %s\n" "$ARCHIVE_SHA256" "$ARCHIVE_PATH" | shasum -a 256 --check

  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

  EXTRACTED_RUNTIME="$(find "$EXTRACT_DIR" -type f -name llama-server | head -1)"
  if [ -z "$EXTRACTED_RUNTIME" ]; then
    echo "error: llama-server not found in $ARCHIVE_NAME" >&2
    exit 1
  fi

  EXTRACTED_RUNTIME_DIR="$(dirname "$EXTRACTED_RUNTIME")"
  rm -rf "$RUNTIME_CACHE_DIR"
  mkdir -p "$RUNTIME_CACHE_DIR"

  cp -p "$EXTRACTED_RUNTIME" "$RUNTIME_CACHE_DIR/llama-server"
  chmod 755 "$RUNTIME_CACHE_DIR/llama-server"

  for dylib in "$EXTRACTED_RUNTIME_DIR"/*.dylib; do
    [ -e "$dylib" ] || continue
    cp -pR "$dylib" "$RUNTIME_CACHE_DIR/$(basename "$dylib")"
  done

  if [ -f "$EXTRACTED_RUNTIME_DIR/LICENSE" ]; then
    cp -p "$EXTRACTED_RUNTIME_DIR/LICENSE" "$RUNTIME_CACHE_DIR/LICENSE"
  fi
fi

rm -f "$DESTINATION_PATH"
rm -f "$DESTINATION_DIR/LICENSE"
rm -f "$DESTINATION_DIR"/libggml*.dylib
rm -f "$DESTINATION_DIR"/libllama*.dylib
rm -f "$DESTINATION_DIR"/libmtmd*.dylib

cp -p "$RUNTIME_CACHE_DIR/llama-server" "$DESTINATION_PATH"
for dylib in "$RUNTIME_CACHE_DIR"/*.dylib; do
  [ -e "$dylib" ] || continue
  cp -pR "$dylib" "$DESTINATION_DIR/$(basename "$dylib")"
done
chmod 755 "$DESTINATION_PATH"

if [ -f "$RUNTIME_CACHE_DIR/LICENSE" ]; then
  mkdir -p "$THIRD_PARTY_DIR"
  cp -p "$RUNTIME_CACHE_DIR/LICENSE" "$THIRD_PARTY_DIR/llama.cpp-LICENSE"
fi

SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [ -n "$SIGN_IDENTITY" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_ARGS+=(--options runtime --timestamp)
  fi

  while IFS= read -r mach_o_file; do
    codesign "${SIGN_ARGS[@]}" "$mach_o_file"
  done < <(find "$DESTINATION_DIR" -maxdepth 1 -type f \( -name '*.dylib' -o -name llama-server \) | sort)
fi

echo "Bundled llama-server at $DESTINATION_PATH"
