#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/.build/release-artifacts}"
BUILD_NUMBER="${NEOANKI_RELEASE_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"
VERSION="${NEOANKI_RELEASE_VERSION:-1.0.$BUILD_NUMBER}"
ARTIFACT_NAME="NeoAnki2-$VERSION-mac-universal.dmg"

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
NEOANKI_INSTALL_CONFIG=release \
NEOANKI_INSTALL_DIR="$PAYLOAD_DIR" \
NEOANKI_INSTALL_VERSION="$VERSION" \
NEOANKI_INSTALL_BUILD_NUMBER="$BUILD_NUMBER" \
NEOANKI_INSTALL_UNIVERSAL=1 \
NEOANKI_INSTALL_ALLOW_RUNNING=1 \
  "$ROOT/Scripts/install-app.sh"

installed_version=$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP_PATH/Contents/Info.plist"
)
if [ "$installed_version" != "$VERSION" ]; then
  echo "Packaged version $installed_version does not match $VERSION." >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH"
lipo "$APP_PATH/Contents/MacOS/NeoAnki2" -verify_arch arm64 x86_64
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
