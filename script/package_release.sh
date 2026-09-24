#!/usr/bin/env bash
set -euo pipefail

# Production release packaging for DictaFlow.
# Archives the DictaFlow scheme (Release), exports a Developer ID signed app,
# verifies it, and creates a versioned distributable DMG.
# Notarization and GitHub publishing are separate release stages, not done here.

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <version>" >&2
  echo "example: $0 2.6.0" >&2
  exit 2
fi

VERSION="$1"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like X.Y.Z, got: $VERSION" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/DictaFlow.xcodeproj"
SCHEME="DictaFlow"
CONFIGURATION="Release"
APP_NAME="DictaFlow"
BUNDLE_ID="com.dictaflow"
EXPECTED_AUTHORITY="Developer ID Application: Rifky Satyana (627M6A6KRH)"
EXPORT_OPTIONS="$ROOT_DIR/Config/ExportOptions.plist"
ARCHIVE_PATH="$ROOT_DIR/.build/DictaFlow.xcarchive"
EXPORT_DIR="$ROOT_DIR/.build/export"
EXPORTED_APP="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/.build/$APP_NAME-$VERSION-arm64.dmg"

if [ ! -f "$EXPORT_OPTIONS" ]; then
  echo "error: export options not found: $EXPORT_OPTIONS" >&2
  exit 1
fi

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_PATH"

echo "==> Archiving $SCHEME ($CONFIGURATION)..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH"

echo "==> Exporting Developer ID app..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR"

echo "==> Verifying exported app..."
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$EXPORTED_APP/Contents/Info.plist")"
BUILT_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$EXPORTED_APP/Contents/Info.plist")"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
  echo "error: expected version $VERSION, got $BUILT_VERSION" >&2
  exit 1
fi
if [ "$BUILT_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  echo "error: expected bundle id $BUNDLE_ID, got $BUILT_BUNDLE_ID" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP"
/usr/bin/codesign -dvvv "$EXPORTED_APP" 2>&1 | grep -q "Authority=$EXPECTED_AUTHORITY"

echo "==> Packaging DMG..."
VOLUME_NAME="$APP_NAME" "$ROOT_DIR/script/package_dmg.sh" "$EXPORTED_APP" "$DMG_PATH"

echo "Release DMG ready: $DMG_PATH"
