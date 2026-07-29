#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_PLAN="${NEOANKI_UI_TEST_PLAN:-FastFunctional}"
DERIVED_DATA_ROOT="${NEOANKI_UI_DERIVED_DATA:-$ROOT/.build/ui-derived-data}"
RESULT_ROOT="${NEOANKI_UI_RESULT_ROOT:-$ROOT/.build/ui-results}"
RESULT_BUNDLE="$RESULT_ROOT/$TEST_PLAN.xcresult"
TOTAL_STARTED=$SECONDS
DIAGNOSTIC_DIR="$RESULT_ROOT/diagnostics"

# Positional filters can name either XCTest journeys or legacy activity IDs:
#   ./Scripts/run-ui-tests.sh FastFunctionalJourneyTests/testLibraryAndBrowseJourney
#   ./Scripts/run-ui-tests.sh LibraryUITests.testAppLaunchesWithEmptyLibrary
JOURNEY_FILTERS=()
ACTIVITY_FILTERS=()
for filter in "$@"; do
  if [[ "$filter" == *Journey* ]]; then
    if [[ "$filter" == NeoAnki2UITests/* ]]; then
      JOURNEY_FILTERS+=("$filter")
    else
      JOURNEY_FILTERS+=("NeoAnki2UITests/$filter")
    fi
  else
    ACTIVITY_FILTERS+=("$filter")
  fi
done

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
RUNNER=$(
  find "$DERIVED_DATA_ROOT" -maxdepth 6 -name 'NeoAnki2UITests-Runner.app' 2>/dev/null \
    | head -1 \
    || true
)
if [[ -n "${NEOANKI_UI_CLEAN:-}" ]] || [[ -z "$RUNNER" ]]; then
  if [[ -d "$DERIVED_DATA_ROOT" ]]; then
    rm -rf "$DERIVED_DATA_ROOT"
  fi
fi

BUILD_STARTED=$SECONDS
xcodebuild build-for-testing \
  -project NeoAnki2UITests.xcodeproj \
  -scheme NeoAnki2UITests \
  -testPlan "$TEST_PLAN" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_ROOT" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES
BUILD_SECONDS=$((SECONDS - BUILD_STARTED))

export NEOANKI_UI_DERIVED_DATA="$DERIVED_DATA_ROOT"
"$ROOT/Scripts/sign-ui-artifacts.sh"

XCTESTRUN=$(find "$DERIVED_DATA_ROOT/Build/Products" -name '*.xctestrun' | head -1)
if [[ -z "$XCTESTRUN" ]]; then
  echo "Could not find xctestrun file." >&2
  exit 1
fi

mkdir -p "$RESULT_ROOT"
rm -rf "$DIAGNOSTIC_DIR"
mkdir -p "$DIAGNOSTIC_DIR"
DIAGNOSTIC_FILTER_KEY=TestConfigurations.0.TestTargets.0.EnvironmentVariables.NEOANKI_UI_DIAGNOSTIC_DIR
if plutil -extract "$DIAGNOSTIC_FILTER_KEY" raw "$XCTESTRUN" >/dev/null 2>&1; then
  plutil -remove "$DIAGNOSTIC_FILTER_KEY" "$XCTESTRUN"
fi
plutil -insert "$DIAGNOSTIC_FILTER_KEY" -string "$DIAGNOSTIC_DIR" "$XCTESTRUN"

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
  IFS=',' read -r -a ONLY_TESTS <<< "$NEOANKI_UI_ONLY_TESTING"
  for test_identifier in "${ONLY_TESTS[@]}"; do
    if [[ -n "$test_identifier" ]]; then
      TEST_ARGUMENTS+=("-only-testing:${test_identifier}")
    fi
  done
fi
if [[ ${#JOURNEY_FILTERS[@]} -gt 0 ]]; then
  for test_identifier in "${JOURNEY_FILTERS[@]}"; do
    TEST_ARGUMENTS+=("-only-testing:${test_identifier}")
  done
fi

if [[ -n "${NEOANKI_UI_ACTIVITY_FILTERS:-}" ]]; then
  IFS=',' read -r -a ENV_ACTIVITY_FILTERS <<< "$NEOANKI_UI_ACTIVITY_FILTERS"
  ACTIVITY_FILTERS+=("${ENV_ACTIVITY_FILTERS[@]}")
fi
ACTIVITY_FILTER_KEY=TestConfigurations.0.TestTargets.0.EnvironmentVariables.NEOANKI_UI_ACTIVITY_FILTERS
if plutil -extract "$ACTIVITY_FILTER_KEY" raw "$XCTESTRUN" >/dev/null 2>&1; then
  plutil -remove "$ACTIVITY_FILTER_KEY" "$XCTESTRUN"
fi
if [[ ${#ACTIVITY_FILTERS[@]} -gt 0 ]]; then
  NEOANKI_UI_ACTIVITY_FILTERS=$(IFS=','; echo "${ACTIVITY_FILTERS[*]}")
  plutil -insert \
    "$ACTIVITY_FILTER_KEY" \
    -string "$NEOANKI_UI_ACTIVITY_FILTERS" \
    "$XCTESTRUN"
fi

# Build the command before expanding it: Bash 3.2 treats an empty array
# expansion as unbound under `set -u`.
TEST_COMMAND=(
  xcodebuild test-without-building
  -xctestrun "$XCTESTRUN"
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED_DATA_ROOT"
  -resultBundlePath "$RESULT_BUNDLE"
  -parallel-testing-enabled NO
)
if [[ ${#TEST_ARGUMENTS[@]} -gt 0 ]]; then
  TEST_COMMAND+=("${TEST_ARGUMENTS[@]}")
fi

rm -rf "$RESULT_BUNDLE"
TEST_STARTED=$SECONDS
"${TEST_COMMAND[@]}" || {
  TEST_SECONDS=$((SECONDS - TEST_STARTED))
  echo "UI timings: build=${BUILD_SECONDS}s test=${TEST_SECONDS}s total=$((SECONDS - TOTAL_STARTED))s"
  echo "Result bundle: $RESULT_BUNDLE"
  echo "UI smoke tests failed." >&2
  exit 1
}
TEST_SECONDS=$((SECONDS - TEST_STARTED))
echo "UI timings: build=${BUILD_SECONDS}s test=${TEST_SECONDS}s total=$((SECONDS - TOTAL_STARTED))s"
echo "Result bundle: $RESULT_BUNDLE"
