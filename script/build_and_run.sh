#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/DictaFlow.xcodeproj"
DEV_SCHEME="DictaFlow Dev"
DEV_CONFIGURATION="Debug"
DEV_DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
DEV_APP_NAME="DictaFlow Dev"
DEV_BUNDLE_ID="com.dictaflow.dev"
DEV_BUILT_APP="$DEV_DERIVED_DATA/Build/Products/$DEV_CONFIGURATION/$DEV_APP_NAME.app"
DEV_INSTALLED_APP="/Applications/$DEV_APP_NAME.app"
PACKAGE_DMG_PATH="$ROOT_DIR/.build/DictaFlow.dmg"
WHISPER_VENDOR_DIR="$ROOT_DIR/Vendor/whisper.cpp"
WHISPER_FRAMEWORK_DIR="$WHISPER_VENDOR_DIR/build-apple/whisper.xcframework"
WHISPER_BUILD_SCRIPT="$WHISPER_VENDOR_DIR/build-xcframework.sh"

MODE="${1:-run}"

usage() {
  echo "usage: $0 [run|--no-launch|--verify|--logs|--telemetry|--debug|--install-dev|--package-dev|--uninstall-dev|--reset-dev]" >&2
}

stop_app() {
  local app_name="$1"
  local bundle_id="$2"

  if ! pgrep -x "$app_name" >/dev/null 2>&1; then
    return
  fi

  /usr/bin/osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  sleep 1

  if pgrep -x "$app_name" >/dev/null 2>&1; then
    pkill -x "$app_name" >/dev/null 2>&1 || true
    sleep 0.5
  fi
}

stop_dev_app() {
  stop_app "$DEV_APP_NAME" "$DEV_BUNDLE_ID"
}

ensure_whisper_xcframework() {
  if [ -d "$WHISPER_FRAMEWORK_DIR" ] && [ "$WHISPER_FRAMEWORK_DIR" -nt "$WHISPER_BUILD_SCRIPT" ]; then
    return 0
  fi

  if [ ! -d "$WHISPER_VENDOR_DIR" ]; then
    echo "error: whisper.cpp vendor sources were not found at $WHISPER_VENDOR_DIR" >&2
    exit 1
  fi

  if [ ! -x "$WHISPER_BUILD_SCRIPT" ]; then
    chmod +x "$WHISPER_BUILD_SCRIPT"
  fi

  echo "Whisper XCFramework missing or outdated, building it first (slow on first run)..."
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  (cd "$WHISPER_VENDOR_DIR" && "$WHISPER_BUILD_SCRIPT")
}

build_dev_app() {
  ensure_whisper_xcframework
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$DEV_SCHEME" \
    -configuration "$DEV_CONFIGURATION" \
    -derivedDataPath "$DEV_DERIVED_DATA" \
    build
}

install_dev_app() {
  # Replace the bundle so removed dependencies cannot survive an update.
  # Keep the previous app recoverable if installation fails or needs rollback.
  local backup_dir
  backup_dir="$ROOT_DIR/.build/AppBackups/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$backup_dir"
  if [[ -e "$DEV_INSTALLED_APP" ]]; then
    mv "$DEV_INSTALLED_APP" "$backup_dir/$DEV_APP_NAME.app"
  fi
  if ! /usr/bin/ditto "$DEV_BUILT_APP" "$DEV_INSTALLED_APP"; then
    if [[ -e "$DEV_INSTALLED_APP" ]]; then
      mv "$DEV_INSTALLED_APP" "$backup_dir/Incomplete installation.app"
    fi
    if [[ -e "$backup_dir/$DEV_APP_NAME.app" ]]; then
      mv "$backup_dir/$DEV_APP_NAME.app" "$DEV_INSTALLED_APP"
    fi
    return 1
  fi
}

uninstall_dev_app() {
  stop_dev_app
  rm -rf "$DEV_INSTALLED_APP"
}

reset_dev_settings() {
  stop_dev_app
  /usr/bin/defaults delete "$DEV_BUNDLE_ID" app.hasPresentedInitialWindow >/dev/null 2>&1 || true
  /usr/bin/defaults delete "$DEV_BUNDLE_ID" permissions.hasRequestedAccessibilityPermission >/dev/null 2>&1 || true
  /usr/bin/tccutil reset Microphone "$DEV_BUNDLE_ID"
  /usr/bin/tccutil reset Accessibility "$DEV_BUNDLE_ID"
}

verify_dev_app() {
  codesign --verify --deep --strict --verbose=2 "$DEV_INSTALLED_APP"
  codesign -dvvv "$DEV_INSTALLED_APP"
}

open_dev_app() {
  /usr/bin/open -n "$DEV_INSTALLED_APP"
}

stream_logs() {
  /usr/bin/log stream --info --style compact --predicate "process == \"$DEV_APP_NAME\""
}

stream_telemetry() {
  /usr/bin/log stream --info --style compact --predicate "subsystem == \"$DEV_BUNDLE_ID\""
}

case "$MODE" in
  run|--run|--no-launch|verify|--verify|logs|--logs|telemetry|--telemetry|debug|--debug)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  --install-dev|install-dev|--package-dev|package-dev|--uninstall-dev|uninstall-dev|--reset-dev|reset-dev)
    ;;
  *)
    usage
    exit 2
    ;;
esac

case "$MODE" in
  run|--run|--no-launch|verify|--verify|logs|--logs|telemetry|--telemetry|debug|--debug)
    stop_dev_app
    build_dev_app
    install_dev_app
    ;;
  --install-dev|install-dev)
    stop_dev_app
    build_dev_app
    install_dev_app
    ;;
  --package-dev|package-dev)
    build_dev_app
    rm -f "$PACKAGE_DMG_PATH"
    "$ROOT_DIR/script/package_dmg.sh" "$DEV_BUILT_APP" "$PACKAGE_DMG_PATH"
    exit 0
    ;;
  --uninstall-dev|uninstall-dev)
    uninstall_dev_app
    exit 0
    ;;
  --reset-dev|reset-dev)
    reset_dev_settings
    exit 0
    ;;
esac

case "$MODE" in
  run|--run)
    open_dev_app
    ;;
  --no-launch)
    ;;
  verify|--verify)
    verify_dev_app
    open_dev_app
    sleep 1
    pgrep -x "$DEV_APP_NAME" >/dev/null
    ;;
  logs|--logs)
    open_dev_app
    stream_logs
    ;;
  telemetry|--telemetry)
    open_dev_app
    stream_telemetry
    ;;
  debug|--debug)
    lldb -- "$DEV_INSTALLED_APP/Contents/MacOS/$DEV_APP_NAME"
    ;;
  --install-dev|install-dev|--package-dev|package-dev|--uninstall-dev|uninstall-dev|--reset-dev|reset-dev)
    ;;
esac
