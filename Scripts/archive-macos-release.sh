#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/.build/signed-release}"
TEAM_ID="${NEOANKI_DEVELOPMENT_TEAM:?Set NEOANKI_DEVELOPMENT_TEAM.}"
PROFILE="${NEOANKI_PROVISIONING_PROFILE_SPECIFIER:?Set the Developer ID CloudKit provisioning profile name.}"
IDENTITY="${NEOANKI_SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NEOANKI_NOTARY_PROFILE:?Set the notarytool keychain profile name.}"
VERSION="${NEOANKI_INSTALL_VERSION:-1.0}"
BUILD_NUMBER="${NEOANKI_INSTALL_BUILD_NUMBER:-1}"
ARCHIVE_PATH="$OUTPUT_DIR/NeoAnki2.xcarchive"
EXPORT_PATH="$OUTPUT_DIR/export"

mkdir -p "$OUTPUT_DIR"

xcodebuild archive \
  -project "$ROOT/Xcode/NeoAnkiMac.xcodeproj" \
  -scheme NeoAnkiMac \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$ROOT/Packaging/ExportOptions-DeveloperID.plist"

APP_PATH="$EXPORT_PATH/NeoAnki2.app"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements :- "$APP_PATH" > "$OUTPUT_DIR/embedded-entitlements.plist"
lipo "$APP_PATH/Contents/MacOS/NeoAnki2" -verify_arch arm64 x86_64

ditto -c -k --keepParent "$APP_PATH" "$OUTPUT_DIR/NeoAnki2-notarization.zip"
NOTARY_ARGUMENTS=(--keychain-profile "$NOTARY_PROFILE" --wait)
if [ -n "${NEOANKI_CI_KEYCHAIN:-}" ]; then
  NOTARY_ARGUMENTS+=(--keychain "$NEOANKI_CI_KEYCHAIN")
fi
xcrun notarytool submit "$OUTPUT_DIR/NeoAnki2-notarization.zip" "${NOTARY_ARGUMENTS[@]}"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

echo "Signed and notarized app: $APP_PATH"
