#!/usr/bin/env bash
set -euo pipefail

# Installs NeoAnki2 into /Applications so it launches like any other Mac app.
#
# This is a release build signed ad-hoc with no entitlements, which is what
# separates it from Scripts/build-test-app.sh: the test bundle grants itself
# get-task-allow and Apple Events so XCUITest can drive it, and an app you use
# on your own library has no business holding either.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${NEOANKI_INSTALL_CONFIG:-release}"
DEST_DIR="${NEOANKI_INSTALL_DIR:-/Applications}"
APP_NAME="NeoAnki2.app"
STAGE="$ROOT/.build/install/$APP_NAME"
RESTART=0

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/install-app.sh [--restart] [--dest DIR]

  --restart    Quit a running NeoAnki2 before installing, and launch the new
               build afterwards. Without it, a running instance is an error:
               two processes sharing one SQLite library corrupt it.
  --dest DIR   Install somewhere other than /Applications.

Environment: NEOANKI_INSTALL_CONFIG (default release),
             NEOANKI_INSTALL_DIR (default /Applications).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --restart) RESTART=1; shift ;;
    --dest) DEST_DIR="${2:?--dest needs a directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

TARGET="$DEST_DIR/$APP_NAME"

if [ ! -d "$DEST_DIR" ]; then
  echo "Destination does not exist: $DEST_DIR" >&2
  exit 1
fi

if [ ! -w "$DEST_DIR" ]; then
  echo "Cannot write to $DEST_DIR." >&2
  echo "Re-run with sudo, or install elsewhere with --dest ~/Applications." >&2
  exit 1
fi

if pgrep -x NeoAnki2 >/dev/null 2>&1; then
  if [ "$RESTART" -eq 0 ]; then
    echo "NeoAnki2 is running. Quit it first, or re-run with --restart." >&2
    exit 1
  fi
  echo "Quitting the running NeoAnki2..."
  osascript -e 'quit app "NeoAnki2"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x NeoAnki2 >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -x NeoAnki2 >/dev/null 2>&1; then
    echo "NeoAnki2 did not quit. Quit it by hand and re-run." >&2
    exit 1
  fi
fi

echo "Building NeoAnki2 ($CONFIG)..."
cd "$ROOT"
swift build -c "$CONFIG"

BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "Assembling $APP_NAME..."
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp "$BUILD_DIR/NeoAnki2" "$STAGE/Contents/MacOS/NeoAnki2"
chmod +x "$STAGE/Contents/MacOS/NeoAnki2"
cp "$ROOT/Packaging/Info.plist" "$STAGE/Contents/Info.plist"

# Local builds have no release version to speak of, so record which commit this
# came from. Without it, two installs a month apart are indistinguishable.
REVISION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
  REVISION="$REVISION-dirty"
fi
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion $BUILD_NUMBER" \
  -c "Add :NeoAnkiGitRevision string $REVISION" \
  "$STAGE/Contents/Info.plist" >/dev/null

xattr -cr "$STAGE" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$STAGE"

echo "Installing to $TARGET..."
rm -rf "$TARGET"
ditto "$STAGE" "$TARGET"

echo "Installed NeoAnki2 ($REVISION, build $BUILD_NUMBER) at $TARGET"

if [ "$RESTART" -eq 1 ]; then
  echo "Launching..."
  open "$TARGET"
fi
