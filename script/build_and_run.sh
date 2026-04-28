#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/DictaFlow.xcodeproj"
SCHEME="DictaFlow Dev"
CONFIGURATION="Debug"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_NAME="DictaFlow Dev"
BUNDLE_ID="com.dictaflow.dev"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"

MODE="${1:-run}"

usage() {
  echo "usage: $0 [run|--no-launch|--verify|--logs|--telemetry|--debug]" >&2
}

stop_app() {
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    return
  fi

  /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 1

  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    sleep 0.5
  fi
}

build_app() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    build
}

install_app() {
  /usr/bin/ditto "$BUILT_APP" "$INSTALLED_APP"
}

verify_app() {
  codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
  codesign -dvvv "$INSTALLED_APP"
}

open_app() {
  /usr/bin/open -n "$INSTALLED_APP"
}

stream_logs() {
  /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
}

stream_telemetry() {
  /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
}

case "$MODE" in
  run|--run|--no-launch|verify|--verify|logs|--logs|telemetry|--telemetry|debug|--debug)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

stop_app
build_app
install_app

case "$MODE" in
  run|--run)
    open_app
    ;;
  --no-launch)
    ;;
  verify|--verify)
    verify_app
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  logs|--logs)
    open_app
    stream_logs
    ;;
  telemetry|--telemetry)
    open_app
    stream_telemetry
    ;;
  debug|--debug)
    lldb -- "$INSTALLED_APP/Contents/MacOS/$APP_NAME"
    ;;
esac
