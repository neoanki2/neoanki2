#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${NEOANKI_UI_DERIVED_DATA:-$ROOT/.build/ui-derived-data}"
ARTIFACT_DIR="$ROOT/.build/macos-ui-artifact"
ARCHIVE="$ARTIFACT_DIR/build-products.tar.gz"
METADATA="$ARTIFACT_DIR/metadata.json"
COMMIT_SHA="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
STARTED=$SECONDS

rm -rf "$DERIVED_DATA" "$ROOT/.build/NeoAnki2.app" "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

NEOANKI_UI_BUILD_ONLY=1 \
NEOANKI_UI_CLEAN=1 \
NEOANKI_UI_DERIVED_DATA="$DERIVED_DATA" \
  "$ROOT/Scripts/run-ui-tests.sh"

tar -czf "$ARCHIVE" -C "$ROOT" \
  .build/NeoAnki2.app \
  .build/ui-derived-data/Build/Products
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

echo "macOS UI build timing: build_and_package=${BUILD_SECONDS}s"
echo "macOS UI build archive: $(du -h "$ARCHIVE" | awk '{print $1}')"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### macOS UI shared build"
    echo
    echo "- Build and package: ${BUILD_SECONDS}s"
    echo "- Archive: $(du -h "$ARCHIVE" | awk '{print $1}')"
    echo "- Revision: \`$COMMIT_SHA\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
