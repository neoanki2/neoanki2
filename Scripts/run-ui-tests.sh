#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cleanup_apps() {
  pkill -x NeoAnki2 2>/dev/null || true
}

trap cleanup_apps EXIT

"$ROOT/Scripts/build-test-app.sh"

cd "$ROOT/UITests"

# Gatekeeper can cache an unsigned runner as "damaged", and the only cure is a
# clean rebuild — but that costs ~12s, so it is not worth paying on every run.
# Discard the cache only when asked, or when the last build left no signed
# runner behind for us to reuse.
DERIVED_DATA_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
RUNNER=$(
  find "$DERIVED_DATA_ROOT" -maxdepth 5 -name 'NeoAnki2UITests-Runner.app' 2>/dev/null \
    | head -1 \
    || true
)
if [[ -n "${NEOANKI_UI_CLEAN:-}" ]] || [[ -z "$RUNNER" ]] \
  || ! codesign --verify --quiet "$RUNNER" 2>/dev/null; then
  if [[ -d "$DERIVED_DATA_ROOT" ]]; then
    find "$DERIVED_DATA_ROOT" \
      -maxdepth 1 \
      -type d \
      -name 'NeoAnki2UITests-*' \
      -exec rm -rf {} +
  fi
fi

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
if [[ -n "${DOC_SCREENSHOT_DIR:-}" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Delete :TestConfigurations:0:TestTargets:0:EnvironmentVariables:DOC_SCREENSHOT_DIR" \
    "$XCTESTRUN" 2>/dev/null || true
  /usr/libexec/PlistBuddy \
    -c "Add :TestConfigurations:0:TestTargets:0:EnvironmentVariables:DOC_SCREENSHOT_DIR string $DOC_SCREENSHOT_DIR" \
    "$XCTESTRUN"
fi

TEST_ARGUMENTS=()
if [[ -n "${NEOANKI_UI_ONLY_TESTING:-}" ]]; then
  TEST_ARGUMENTS+=("-only-testing:${NEOANKI_UI_ONLY_TESTING}")
fi

# Build the command before expanding it: Bash 3.2 treats an empty array
# expansion as unbound under `set -u`.
TEST_COMMAND=(
  xcodebuild test-without-building
  -xctestrun "$XCTESTRUN"
  -destination 'platform=macOS'
)
if [[ ${#TEST_ARGUMENTS[@]} -gt 0 ]]; then
  TEST_COMMAND+=("${TEST_ARGUMENTS[@]}")
fi

"${TEST_COMMAND[@]}" || {
  echo "UI smoke tests failed." >&2
  exit 1
}
