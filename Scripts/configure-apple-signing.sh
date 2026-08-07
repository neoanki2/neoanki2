#!/usr/bin/env bash
set -euo pipefail

P12_BASE64="${APPLE_DEVELOPER_ID_P12_BASE64:?Missing Developer ID certificate data.}"
P12_PASSWORD="${APPLE_DEVELOPER_ID_P12_PASSWORD:?Missing certificate password.}"
PROFILE_BASE64="${APPLE_DEVELOPER_ID_PROFILE_BASE64:?Missing provisioning profile data.}"
APPLE_ID="${APPLE_NOTARY_APPLE_ID:?Missing notarization Apple ID.}"
APP_PASSWORD="${APPLE_NOTARY_PASSWORD:?Missing notarization app password.}"
TEAM_ID="${APPLE_DEVELOPMENT_TEAM:?Missing Apple team ID.}"
KEYCHAIN_PASSWORD="${APPLE_CI_KEYCHAIN_PASSWORD:?Missing temporary keychain password.}"
CI_TEMP="${RUNNER_TEMP:?This helper is intended for an ephemeral CI runner.}"

KEYCHAIN_PATH="$CI_TEMP/neoanki-signing.keychain-db"
CERTIFICATE_PATH="$CI_TEMP/developer-id.p12"
PROFILE_PATH="$CI_TEMP/neoanki.provisionprofile"
PROFILE_PLIST="$CI_TEMP/neoanki-profile.plist"

printf '%s' "$P12_BASE64" | base64 --decode > "$CERTIFICATE_PATH"
printf '%s' "$PROFILE_BASE64" | base64 --decode > "$PROFILE_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" -k "$KEYCHAIN_PATH" -P "$P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH"

security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST"
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_PLIST")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST")
PROFILES_DIRECTORY="${HOME:?Missing runner home}/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILES_DIRECTORY"
cp "$PROFILE_PATH" "$PROFILES_DIRECTORY/$PROFILE_UUID.provisionprofile"

xcrun notarytool store-credentials neoanki-ci-notary \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --keychain "$KEYCHAIN_PATH"

echo "APPLE_DEVELOPER_ID_PROFILE_NAME=$PROFILE_NAME" >> "${GITHUB_ENV:?Missing GitHub environment file.}"
echo "NEOANKI_CI_KEYCHAIN=$KEYCHAIN_PATH" >> "$GITHUB_ENV"
