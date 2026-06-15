#!/usr/bin/env bash
set -euo pipefail

for name in DEVELOPER_ID_CERTIFICATE_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD KEYCHAIN_PASSWORD; do
  if [ -z "${!name:-}" ]; then
    echo "error: missing required environment variable: $name" >&2
    exit 1
  fi
done

KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/dictaflow-signing.keychain-db"
CERTIFICATE_PATH="${RUNNER_TEMP:-/tmp}/developer-id-certificate.p12"

printf "%s" "$DEVELOPER_ID_CERTIFICATE_BASE64" | base64 --decode > "$CERTIFICATE_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" -P "$DEVELOPER_ID_CERTIFICATE_PASSWORD" -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"
