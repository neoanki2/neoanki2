#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cleanup_apps() {
  pkill -x NeoAnki2 2>/dev/null || true
}

trap cleanup_apps EXIT

"$ROOT/Scripts/build-test-app.sh"

cd "$ROOT/UITests"

# Remove stale unsigned runners that Gatekeeper may have cached as "damaged".
rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/NeoAnki2UITests-*

xcodebuild build-for-testing \
  -project NeoAnki2UITests.xcodeproj \
  -scheme NeoAnki2UITests \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES

"$ROOT/Scripts/sign-ui-artifacts.sh"

XCTESTRUN=$(find "$HOME/Library/Developer/Xcode/DerivedData/NeoAnki2UITests-"*/Build/Products -name '*.xctestrun' | head -1)
if [[ -z "$XCTESTRUN" ]]; then
  echo "Could not find xctestrun file." >&2
  exit 1
fi

APP_PATH="$ROOT/.build/NeoAnki2.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle at $APP_PATH" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Delete :TestConfigurations:0:TestTargets:0:UITargetAppPath" "$XCTESTRUN" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :TestConfigurations:0:TestTargets:0:UITargetAppPath string $APP_PATH" "$XCTESTRUN"

xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination 'platform=macOS' || {
  echo "UI smoke tests failed." >&2
  exit 1
}
