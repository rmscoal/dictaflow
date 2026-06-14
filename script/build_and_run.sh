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

RELEASE_SCHEME="DictaFlow"
RELEASE_CONFIGURATION="Release"
RELEASE_DERIVED_DATA="$ROOT_DIR/.build/ReleaseDerivedData"
RELEASE_APP_NAME="DictaFlow"
RELEASE_BUNDLE_ID="com.dictaflow"
RELEASE_BUILT_APP="$RELEASE_DERIVED_DATA/Build/Products/$RELEASE_CONFIGURATION/$RELEASE_APP_NAME.app"
RELEASE_INSTALLED_APP="/Applications/$RELEASE_APP_NAME.app"
PACKAGE_DMG_PATH="$ROOT_DIR/.build/DictaFlow-local.dmg"

MODE="${1:-run}"

usage() {
  echo "usage: $0 [run|--no-launch|--verify|--logs|--telemetry|--debug|--install-dev|--install-release|--package|--uninstall]" >&2
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

stop_release_app() {
  stop_app "$RELEASE_APP_NAME" "$RELEASE_BUNDLE_ID"
}

build_dev_app() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$DEV_SCHEME" \
    -configuration "$DEV_CONFIGURATION" \
    -derivedDataPath "$DEV_DERIVED_DATA" \
    build
}

build_release_app() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$RELEASE_SCHEME" \
    -configuration "$RELEASE_CONFIGURATION" \
    -derivedDataPath "$RELEASE_DERIVED_DATA" \
    DEVELOPMENT_TEAM= \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    SWIFT_OPTIMIZATION_LEVEL=-Onone \
    build
}

install_dev_app() {
  /usr/bin/ditto "$DEV_BUILT_APP" "$DEV_INSTALLED_APP"
}

install_release_app() {
  /usr/bin/ditto "$RELEASE_BUILT_APP" "$RELEASE_INSTALLED_APP"
}

uninstall_apps() {
  stop_dev_app
  stop_release_app

  rm -rf "$DEV_INSTALLED_APP" "$RELEASE_INSTALLED_APP"
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
  --install-dev|install-dev|--install-release|install-release|--package|package|--uninstall|uninstall)
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
  --install-release|install-release)
    stop_release_app
    build_release_app
    install_release_app
    ;;
  --package|package)
    build_release_app
    /usr/bin/rm -f "$PACKAGE_DMG_PATH"
    "$ROOT_DIR/script/package_dmg.sh" "$RELEASE_BUILT_APP" "$PACKAGE_DMG_PATH"
    exit 0
    ;;
  --uninstall|uninstall)
    uninstall_apps
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
  --install-dev|install-dev|--install-release|install-release|--package|package|--uninstall|uninstall)
    ;;
esac
