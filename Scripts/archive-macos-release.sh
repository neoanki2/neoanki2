#!/usr/bin/env bash
set -euo pipefail

# Compatibility entry point: assemble the same universal bundle as the default
# packager, preserving its source revision, then sign and notarize it.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/.build/signed-release}"
mkdir -p "$OUTPUT_DIR/export"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
NEOANKI_INSTALL_CONFIG=release \
NEOANKI_INSTALL_DIR="$OUTPUT_DIR/export" \
NEOANKI_INSTALL_UNIVERSAL=1 \
NEOANKI_INSTALL_ALLOW_RUNNING=1 \
NEOANKI_INSTALL_SIGNED=1 \
NEOANKI_INSTALL_NOTARIZE=1 \
  "$ROOT/Scripts/install-app.sh"
cp "$ROOT/.build/install/notarization.json" "$OUTPUT_DIR/notarization.json"
echo "Signed and notarized app: $OUTPUT_DIR/export/NeoAnki2.app"
