#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 /path/to/DictaFlow.app /path/to/DictaFlow-version.dmg" >&2
  exit 2
fi

APP_PATH="$1"
DMG_PATH="$2"

if [ ! -d "$APP_PATH" ]; then
  echo "error: app bundle not found: $APP_PATH" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH")"
if [ "${DICTAFLOW_LOCAL_TEST_DMG:-0}" = "1" ]; then
  VOLUME_NAME="${VOLUME_NAME:-DictaFlow Local Test}"
else
  VOLUME_NAME="${VOLUME_NAME:-DictaFlow}"
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING_DIR="$ROOT_DIR/.build/dmg-staging"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

if [ "${DICTAFLOW_LOCAL_TEST_DMG:-0}" = "1" ]; then
  cat > "$STAGING_DIR/LOCAL_TEST_BUILD.txt" <<'EOF'
This DictaFlow DMG is a local ad-hoc test build.

It is not Developer ID signed, notarized, or intended for public distribution.
Use it only to test local packaging and installation.
EOF
fi

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [ -n "${DMG_CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$DMG_CODE_SIGN_IDENTITY" "$DMG_PATH"
fi

if [ "${GENERATE_SHA256:-0}" = "1" ]; then
  shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
  echo "Created $DMG_PATH.sha256"
fi

echo "Created $DMG_PATH"
