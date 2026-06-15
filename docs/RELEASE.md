# Release Process

DictaFlow ships public macOS builds as GitHub Release assets. The release
artifact is a signed, notarized, and stapled `.dmg` containing `DictaFlow.app`.

The repository also supports local ad-hoc DMG packaging so the install flow can
be tested before Apple Developer Program membership is available. Ad-hoc builds
are for local testing only and should not be the primary public download.

## Release Engine Overview

The release engine is the set of project targets, scripts, and CI workflow that
turn the source tree into an installable macOS app. It has two lanes:

- Local packaging: builds `DictaFlow.app` with ad-hoc signing and creates a
  `.dmg` for testing the install flow.
- Public release: builds `DictaFlow.app` with Developer ID signing, notarizes
  the `.dmg` with Apple, staples the notarization ticket, and publishes the
  artifact to GitHub Releases.

The development app and public app are intentionally separate:

- `DictaFlow Dev` is the day-to-day development target. It uses bundle id
  `com.dictaflow.dev` and can use local developer tools such as a Homebrew
  `llama-server`.
- `DictaFlow` is the public distribution target. It uses bundle id
  `com.dictaflow` and bundles its own `llama-server` runtime so users do not
  need to install llama.cpp separately.

The important pieces are:

| File | Role |
| --- | --- |
| `DictaFlow.xcodeproj/project.pbxproj` | Defines the `DictaFlow` and `DictaFlow Dev` targets, bundle ids, signing settings, hardened runtime, entitlements, and release build phases. |
| `.github/workflows/release.yml` | Future CI path for signed, notarized GitHub Release DMGs. It requires Apple Developer credentials in GitHub Secrets. |
| `script/ensure_llama_server.sh` | Downloads a pinned llama.cpp release, verifies its checksum, copies `llama-server` and dylibs into the app bundle, and signs them. |
| `script/package_dmg.sh` | Creates the installer DMG with `DictaFlow.app` and an `/Applications` symlink. |
| `script/verify_release_artifact.sh` | Mounts the DMG and verifies app signing, bundled `llama-server`, and optionally notarization. |
| `script/ci_import_certificate.sh` | Imports the Developer ID certificate into a temporary CI keychain for release signing. |
| `ci/ExportOptions-DeveloperID.plist` | Tells `xcodebuild -exportArchive` to export a Developer ID signed macOS app. |
| `Config/DictaFlow.entitlements` | Holds the app entitlements used by both targets. |
| `Makefile` and `script/build_and_run.sh` | Provide local commands such as `make package`, `make install-release`, and `make uninstall`. |

Without Apple Developer Program membership, only the local packaging lane is
expected to work. That lane is useful for checking that the public target builds,
that `llama-server` is bundled, and that the DMG layout is correct. It does not
prove that Gatekeeper will accept the app on another Mac.

For a real public download, the DMG must be built with a Developer ID
Application certificate, notarized by Apple, stapled, and verified with
`spctl`/`stapler`.

## Distribution Targets

| Target | Bundle ID | Purpose |
| --- | --- | --- |
| `DictaFlow Dev` | `com.dictaflow.dev` | Local development and contributor builds. |
| `DictaFlow` | `com.dictaflow` | Public release builds. |

Keep these identities separate. macOS privacy permissions, including
Accessibility approval, are tied to app identity and code identity. Users still
grant Accessibility manually, but stable Developer ID signing makes that trust
survive app updates more predictably.

## What Requires Apple Developer Program Membership

Required for public releases:

- Developer ID Application certificate.
- Notarization through Apple's notary service.
- Stapling the notarization ticket to the DMG.

Not required for local release-flow testing:

- Building the `DictaFlow` target with ad-hoc signing.
- Creating a local `.dmg`.
- Verifying bundle structure and embedded framework signing.

## Local Ad-Hoc DMG Test

Use `make package` before Developer ID credentials exist. If you want to run
the steps manually, use:

```sh
xcodebuild \
  -project DictaFlow.xcodeproj \
  -scheme DictaFlow \
  -configuration Release \
  -derivedDataPath .build/ReleaseDerivedData \
  build \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  SWIFT_OPTIMIZATION_LEVEL=-Onone

./script/package_dmg.sh \
  .build/ReleaseDerivedData/Build/Products/Release/DictaFlow.app \
  .build/DictaFlow-local.dmg

./script/verify_release_artifact.sh .build/DictaFlow-local.dmg
```

This validates packaging only. It does not validate Gatekeeper acceptance,
notarization, or long-lived Accessibility trust.

Note: the current Xcode 26.4 Release optimizer crashes in
`RecordingOverlayCoordinator.swift`. The local packaging command and CI workflow
temporarily pass `SWIFT_OPTIMIZATION_LEVEL=-Onone` so release packaging can be
validated before that compiler-crash workaround is replaced with a source-level
fix.

## GitHub Release Workflow

The release workflow is `.github/workflows/release.yml`. It publishes only when
the workflow runs from a tag that matches `v*`, for example:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Manual `workflow_dispatch` runs are allowed only when the selected ref is also a
`v*` tag. This prevents accidentally notarizing and publishing a branch build.

The workflow:

1. Imports the Developer ID certificate into a temporary CI keychain.
2. Archives the `DictaFlow` scheme in Release configuration.
3. Exports a Developer ID signed app.
4. Bundles the pinned `llama-server` runtime through the public target build phase.
5. Packages the app into a DMG.
6. Signs the DMG.
7. Submits the DMG to Apple's notary service.
8. Staples the notarization ticket.
9. Verifies the DMG, app, and bundled `llama-server` with `codesign`, `stapler`, and `spctl`.
10. Uploads the `.dmg` and `.sha256` checksum to the GitHub Release.

## Bundled Llama Runtime

Public builds bundle `llama-server` so users do not need Homebrew, Ollama, or a
separate llama.cpp install. The build phase runs:

```sh
script/ensure_llama_server.sh "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
```

The script currently pins llama.cpp `b9627` and verifies the official macOS
archive checksum before copying `llama-server` into
`DictaFlow.app/Contents/MacOS/llama-server`.

When updating llama.cpp:

1. Pick a specific release tag.
2. Update `LLAMA_CPP_VERSION` defaults and SHA-256 values in
   `script/ensure_llama_server.sh`.
3. Build the public `DictaFlow` target.
4. Verify the DMG with `script/verify_release_artifact.sh`.
5. Manually test refinement startup and repeated transcript cleanup.

## Required GitHub Secrets

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_IDENTITY` | Full codesigning identity name, such as `Developer ID Application: Example Name (TEAMID)`. |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded `.p12` export of the Developer ID Application certificate and private key. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12`. |
| `KEYCHAIN_PASSWORD` | Random password for the temporary CI keychain. |
| `APPLE_ID` | Apple ID used for notarization. |
| `APPLE_TEAM_ID` | Apple Developer Team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization. |

## Manual Verification

After downloading the GitHub Release DMG on a clean Mac:

```sh
xcrun stapler validate DictaFlow-v1.0.0.dmg
spctl -a -vv -t open --context context:primary-signature DictaFlow-v1.0.0.dmg
```

Then install into `/Applications`, launch `DictaFlow`, approve Microphone, test
recording, approve Accessibility when prompted, and verify insertion into at
least TextEdit and a browser text field.

## Accessibility Notes

Signing and notarization do not grant Accessibility permission automatically.
They make the distributed app's identity stable and trusted by Gatekeeper.

If a user has trouble after updating:

1. Quit DictaFlow.
2. Remove DictaFlow from System Settings > Privacy & Security > Accessibility.
3. Reopen DictaFlow from `/Applications`.
4. Trigger insertion and approve Accessibility again.

This should be rare for properly signed updates, but it is common during local
development when app paths, bundle IDs, and signatures change.
