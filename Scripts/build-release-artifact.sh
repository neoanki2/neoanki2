#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/.build/release-artifacts}"
BUILD_NUMBER="${NEOANKI_RELEASE_BUILD_NUMBER:?Use Scripts/release.sh to allocate the shared build number}"
VERSION="${NEOANKI_RELEASE_VERSION:?Use Scripts/release.sh to allocate the shared version}"
ARTIFACT_NAME="NeoAnki2-$VERSION-mac-universal.dmg"

# Published artifacts always carry real signing capabilities. Never silently
# downgrade a release when signing material or Apple's service is unavailable.
if [ "${NEOANKI_RELEASE_SIGNED:-1}" != "1" ]; then
  echo "Mac releases require Developer ID, production CloudKit, and notarization." >&2
  exit 1
fi
python3 "$ROOT/Scripts/sign-macos-app.py" --check

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  echo "Invalid release version: $VERSION" >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid release build number: $BUILD_NUMBER" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/neoanki2-release.XXXXXX")"
PAYLOAD_DIR="$WORK_DIR/payload"
APP_PATH="$PAYLOAD_DIR/NeoAnki2.app"
ARTIFACT_PATH="$OUTPUT_DIR/$ARTIFACT_NAME"
CHECKSUM_PATH="$ARTIFACT_PATH.sha256"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$PAYLOAD_DIR"
# Keep the universal release graph separate from concurrent native debug tests.
# SwiftPM otherwise serializes both jobs on the root .build workspace lock.
NEOANKI_INSTALL_CONFIG=release \
NEOANKI_INSTALL_DIR="$PAYLOAD_DIR" \
NEOANKI_INSTALL_VERSION="$VERSION" \
NEOANKI_INSTALL_BUILD_NUMBER="$BUILD_NUMBER" \
NEOANKI_INSTALL_UNIVERSAL=1 \
NEOANKI_INSTALL_SCRATCH_PATH="${NEOANKI_INSTALL_SCRATCH_PATH:-$ROOT/.build/release-universal}" \
NEOANKI_INSTALL_ALLOW_RUNNING=1 \
NEOANKI_INSTALL_SIGNED=1 \
NEOANKI_INSTALL_NOTARIZE=1 \
  "$ROOT/Scripts/install-app.sh"
cp "$ROOT/.build/install/notarization.json" "$OUTPUT_DIR/notarization.json"

installed_version=$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP_PATH/Contents/Info.plist"
)
installed_build=$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP_PATH/Contents/Info.plist"
)
if [ "$installed_version" != "$VERSION" ] || [ "$installed_build" != "$BUILD_NUMBER" ]; then
  echo "Packaged identity $installed_version ($installed_build) does not match $VERSION ($BUILD_NUMBER)." >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH"
"$ROOT/Scripts/verify-universal-macos.sh" "$APP_PATH/Contents/MacOS/NeoAnki2"
python3 "$ROOT/Scripts/sign-macos-app.py" --verify "$APP_PATH"
ln -s /Applications "$PAYLOAD_DIR/Applications"

rm -f "$ARTIFACT_PATH" "$CHECKSUM_PATH"
hdiutil create \
  -volname "NeoAnki2 $VERSION" \
  -srcfolder "$PAYLOAD_DIR" \
  -format UDZO \
  -ov \
  "$ARTIFACT_PATH"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$ARTIFACT_NAME" > "$ARTIFACT_NAME.sha256"
)

echo "Release artifact: $ARTIFACT_PATH"
echo "Checksum: $CHECKSUM_PATH"
