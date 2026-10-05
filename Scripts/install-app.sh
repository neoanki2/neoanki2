#!/usr/bin/env bash
set -euo pipefail

# Installs NeoAnki2 into /Applications so it launches like any other Mac app.
#
# Ordinary local installs require Developer ID and production CloudKit.
# Distribution packaging additionally requires accepted Apple notarization.
# Explicit NEOANKI_INSTALL_SIGNED=0 is only for unprovisioned development bundles.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${NEOANKI_INSTALL_CONFIG:-release}"
DEST_DIR="${NEOANKI_INSTALL_DIR:-/Applications}"
VERSION="${NEOANKI_INSTALL_VERSION:-1.0}"
UNIVERSAL="${NEOANKI_INSTALL_UNIVERSAL:-0}"
ALLOW_RUNNING="${NEOANKI_INSTALL_ALLOW_RUNNING:-0}"
SIGNED="${NEOANKI_INSTALL_SIGNED:-1}"
NOTARIZE="${NEOANKI_INSTALL_NOTARIZE:-0}"
BUILD_NUMBER="${NEOANKI_INSTALL_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)}"
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
             NEOANKI_INSTALL_DIR (default /Applications),
             NEOANKI_INSTALL_VERSION (default 1.0),
             NEOANKI_INSTALL_BUILD_NUMBER (default Git revision count),
             NEOANKI_INSTALL_UNIVERSAL (0 or 1; default 0),
             NEOANKI_INSTALL_ALLOW_RUNNING (0 or 1; packaging only),
             NEOANKI_INSTALL_SIGNED (default 1; 0 for development only),
             NEOANKI_INSTALL_NOTARIZE (default 0; releases require 1),
             NEOANKI_SIGNING_DIR (default saved NeoAnki2 Signing directory).
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

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  echo "Invalid app version: $VERSION" >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid app build number: $BUILD_NUMBER" >&2
  exit 1
fi

if [ "$UNIVERSAL" != "0" ] && [ "$UNIVERSAL" != "1" ]; then
  echo "NEOANKI_INSTALL_UNIVERSAL must be 0 or 1." >&2
  exit 1
fi

if [ "$ALLOW_RUNNING" != "0" ] && [ "$ALLOW_RUNNING" != "1" ]; then
  echo "NEOANKI_INSTALL_ALLOW_RUNNING must be 0 or 1." >&2
  exit 1
fi

if [ "$SIGNED" != "0" ] && [ "$SIGNED" != "1" ]; then
  echo "NEOANKI_INSTALL_SIGNED must be 0 or 1." >&2
  exit 1
fi
if [ "$NOTARIZE" != "0" ] && [ "$NOTARIZE" != "1" ]; then
  echo "NEOANKI_INSTALL_NOTARIZE must be 0 or 1." >&2
  exit 1
fi
if [ "$NOTARIZE" -eq 1 ] && [ "$SIGNED" -ne 1 ]; then
  echo "Notarization requires Developer ID signing." >&2
  exit 1
fi
SIGNING_ARGUMENTS=()
[ "$NOTARIZE" -eq 1 ] || SIGNING_ARGUMENTS+=(--sign-only)
if [ "$SIGNED" -eq 1 ]; then
  python3 "$ROOT/Scripts/sign-macos-app.py" --check ${SIGNING_ARGUMENTS[@]+"${SIGNING_ARGUMENTS[@]}"}
fi

if [ ! -d "$DEST_DIR" ]; then
  echo "Destination does not exist: $DEST_DIR" >&2
  exit 1
fi

if [ ! -w "$DEST_DIR" ]; then
  echo "Cannot write to $DEST_DIR." >&2
  echo "Re-run with sudo, or install elsewhere with --dest ~/Applications." >&2
  exit 1
fi

if [ "$ALLOW_RUNNING" -eq 0 ] && pgrep -x NeoAnki2 >/dev/null 2>&1; then
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
BUILD_ARGUMENTS=(-c "$CONFIG")
if [ "$UNIVERSAL" -eq 1 ]; then
  BUILD_ARGUMENTS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGUMENTS[@]}"

BUILD_DIR="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)"

echo "Assembling $APP_NAME..."
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD_DIR/NeoAnki2" "$STAGE/Contents/MacOS/NeoAnki2"
chmod +x "$STAGE/Contents/MacOS/NeoAnki2"
cp "$ROOT/Packaging/Info.plist" "$STAGE/Contents/Info.plist"
cp "$ROOT/Packaging/NeoAnki2.icns" "$STAGE/Contents/Resources/NeoAnki2.icns"

# Local builds have no release version to speak of, so record which commit this
# came from. Without it, two installs a month apart are indistinguishable.
REVISION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if ! git -C "$ROOT" diff --quiet HEAD 2>/dev/null; then
  REVISION="$REVISION-dirty"
fi
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $VERSION" \
  -c "Set :CFBundleVersion $BUILD_NUMBER" \
  -c "Add :NeoAnkiGitRevision string $REVISION" \
  "$STAGE/Contents/Info.plist" >/dev/null

xattr -cr "$STAGE" 2>/dev/null || true
if [ "$SIGNED" -eq 1 ]; then
  python3 "$ROOT/Scripts/sign-macos-app.py" ${SIGNING_ARGUMENTS[@]+"${SIGNING_ARGUMENTS[@]}"} "$STAGE"
else
  codesign --force --sign - --timestamp=none "$STAGE"
fi

echo "Installing to $TARGET..."
rm -rf "$TARGET"
ditto "$STAGE" "$TARGET"

echo "Installed NeoAnki2 ($REVISION, build $BUILD_NUMBER) at $TARGET"

if [ "$RESTART" -eq 1 ]; then
  echo "Launching..."
  open "$TARGET"
fi
