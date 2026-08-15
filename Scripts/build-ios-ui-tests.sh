#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/ios-ui-derived-data"
ARTIFACT_DIR="$ROOT/.build/ios-ui-artifact"
ARCHIVE="$ARTIFACT_DIR/build-products.tar.gz"
METADATA="$ARTIFACT_DIR/metadata.json"
COMMIT_SHA="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
STARTED=$SECONDS

rm -rf "$DERIVED_DATA" "$ARTIFACT_DIR"
mkdir -p \
  "$DERIVED_DATA" \
  "$ARTIFACT_DIR" \
  "$ROOT/build/Debug-iphonesimulator" \
  "$ROOT/NeoAnkiCore/build/Debug-iphonesimulator"

xcodebuild build-for-testing \
  -quiet \
  -project "$ROOT/Xcode/NeoAnkiiOS.xcodeproj" \
  -scheme NeoAnki2MobileUITests \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  COPY_PHASE_STRIP=NO \
  STRIP_INSTALLED_PRODUCT=NO \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO

PRODUCTS="$DERIVED_DATA/Build/Products"
XCTESTRUN_COUNT=$(find "$PRODUCTS" -maxdepth 2 -name '*.xctestrun' | wc -l | tr -d ' ')
if [[ "$XCTESTRUN_COUNT" != "1" ]]; then
  echo "Expected one iOS UI xctestrun file, found $XCTESTRUN_COUNT." >&2
  exit 1
fi

tar -czf "$ARCHIVE" -C "$ROOT" .build/ios-ui-derived-data/Build/Products
ARCHIVE_SHA256=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
XCODE_VERSION=$(xcodebuild -version | paste -sd ';' -)
BUILD_SECONDS=$((SECONDS - STARTED))

jq -n \
  --arg commit_sha "$COMMIT_SHA" \
  --arg xcode_version "$XCODE_VERSION" \
  --arg architecture "$(uname -m)" \
  --arg workspace_path "$ROOT" \
  --arg archive_sha256 "$ARCHIVE_SHA256" \
  --argjson build_seconds "$BUILD_SECONDS" \
  '{
    schema_version: 1,
    commit_sha: $commit_sha,
    xcode_version: $xcode_version,
    architecture: $architecture,
    workspace_path: $workspace_path,
    archive_sha256: $archive_sha256,
    build_seconds: $build_seconds
  }' > "$METADATA"

echo "iOS UI build timing: build_and_package=${BUILD_SECONDS}s"
echo "iOS UI build archive: $(du -h "$ARCHIVE" | awk '{print $1}')"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### iOS UI shared build"
    echo
    echo "- Build and package: ${BUILD_SECONDS}s"
    echo "- Archive: $(du -h "$ARCHIVE" | awk '{print $1}')"
    echo "- Revision: \`$COMMIT_SHA\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
