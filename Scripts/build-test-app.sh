#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/debug"
APP_DIR="$ROOT/.build/NeoAnki2.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Building NeoAnki2..."
cd "$ROOT"
swift build -c debug

mkdir -p "$MACOS" "$RESOURCES"
cp "$BUILD_DIR/NeoAnki2" "$MACOS/NeoAnki2"
cp "$ROOT/Packaging/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Packaging/NeoAnki2.icns" "$RESOURCES/NeoAnki2.icns"
chmod +x "$MACOS/NeoAnki2"
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none \
  --entitlements "$ROOT/UITests/AppBundle/NeoAnki2.entitlements" \
  "$APP_DIR"

echo "App bundle ready at $APP_DIR"
