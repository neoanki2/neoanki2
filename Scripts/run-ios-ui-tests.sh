#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${DEVICE:?DEVICE must name the required simulator device type}"
SHARD_ID="${NEOANKI_IOS_UI_SHARD:-all}"
PARALLEL_WORKERS="${NEOANKI_IOS_UI_PARALLEL_WORKERS:-1}"
ARTIFACT_DIR="$ROOT/.build/ios-ui-artifact"
DERIVED_DATA="$ROOT/.build/ios-ui-derived-data"
RESULT_ROOT="$ROOT/.build/ios-ui-results"
ARCHIVE="$ARTIFACT_DIR/build-products.tar.gz"
METADATA="$ARTIFACT_DIR/metadata.json"
TOTAL_STARTED=$SECONDS
SIMULATOR_IDS_FILE="$RESULT_ROOT/simulator-ids.txt"

# Invoked indirectly by the EXIT trap.
# shellcheck disable=SC2329
cleanup_simulators() {
  [[ -f "$SIMULATOR_IDS_FILE" ]] || return 0
  while IFS= read -r simulator_id; do
    [[ -n "$simulator_id" ]] || continue
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  done < "$SIMULATOR_IDS_FILE"
}
trap cleanup_simulators EXIT

if [[ ! "$PARALLEL_WORKERS" =~ ^[1-4]$ ]]; then
  echo "NEOANKI_IOS_UI_PARALLEL_WORKERS must be an integer from 1 through 4." >&2
  exit 64
fi

TEST_ARGUMENTS=()
EXPECTED_TESTS=0
if [[ -n "${NEOANKI_IOS_UI_ONLY_TESTING:-}" ]]; then
  IFS=',' read -r -a only_tests <<< "$NEOANKI_IOS_UI_ONLY_TESTING"
  for test_identifier in "${only_tests[@]}"; do
    [[ -n "$test_identifier" ]] || continue
    TEST_ARGUMENTS+=("-only-testing:$test_identifier")
    EXPECTED_TESTS=$((EXPECTED_TESTS + 1))
  done
fi

for required in "$ARCHIVE" "$METADATA"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing iOS UI build artifact: $required" >&2
    exit 1
  fi
done

EXPECTED_SHA="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
EXPECTED_XCODE=$(xcodebuild -version | paste -sd ';' -)
EXPECTED_ARCH=$(uname -m)
jq -e \
  --arg sha "$EXPECTED_SHA" \
  --arg xcode "$EXPECTED_XCODE" \
  --arg arch "$EXPECTED_ARCH" \
  --arg workspace "$ROOT" \
  '.schema_version == 1
    and .commit_sha == $sha
    and .xcode_version == $xcode
    and .architecture == $arch
    and .workspace_path == $workspace' \
  "$METADATA" >/dev/null || {
    echo "The downloaded UI build does not match this revision, Xcode, architecture, and workspace." >&2
    jq . "$METADATA" >&2
    exit 1
  }

EXPECTED_ARCHIVE_SHA=$(jq -r '.archive_sha256' "$METADATA")
ACTUAL_ARCHIVE_SHA=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [[ "$ACTUAL_ARCHIVE_SHA" != "$EXPECTED_ARCHIVE_SHA" ]]; then
  echo "The downloaded UI build archive checksum does not match its metadata." >&2
  exit 1
fi

rm -rf "$DERIVED_DATA" "$RESULT_ROOT"
mkdir -p "$RESULT_ROOT"
: > "$SIMULATOR_IDS_FILE"
tar -xzf "$ARCHIVE" -C "$ROOT"

XCTESTRUN=$(find "$DERIVED_DATA/Build/Products" -maxdepth 2 -name '*.xctestrun' | head -1)
if [[ -z "$XCTESTRUN" ]]; then
  echo "Could not find the downloaded iOS UI xctestrun file." >&2
  exit 1
fi

RUNTIME_ID=$(xcrun simctl list runtimes -j | jq -r '
  [.runtimes[]
    | select(.isAvailable == true)
    | select(.identifier | contains("SimRuntime.iOS-"))
    | . + {versionParts: (.version | split(".") | map(tonumber))}]
  | sort_by(.versionParts)
  | last
  | .identifier // empty
')
DEVICE_TYPE_ID=$(xcrun simctl list devicetypes -j | jq -r \
  --arg device "$DEVICE" \
  '.devicetypes[] | select(.name == $device) | .identifier' | head -1)
if [[ -z "$RUNTIME_ID" || -z "$DEVICE_TYPE_ID" ]]; then
  echo "Required iOS runtime or device type is unavailable: $DEVICE" >&2
  xcrun simctl list runtimes
  xcrun simctl list devicetypes
  exit 1
fi

safe_device=$(printf '%s' "$DEVICE" | tr -cs '[:alnum:]' '-')
attempt=1
while [[ $attempt -le 2 ]]; do
  simulator_name="NeoAnki2-CI-${safe_device}-${GITHUB_RUN_ID:-local}-${attempt}"
  simulator_id=$(xcrun simctl create "$simulator_name" "$DEVICE_TYPE_ID" "$RUNTIME_ID")
  printf '%s\n' "$simulator_id" >> "$SIMULATOR_IDS_FILE"
  xcrun simctl boot "$simulator_id"
  xcrun simctl bootstatus "$simulator_id" -b
  # Use the supported Simulator UI setting so SwiftUI's read-only
  # colorSchemeContrast environment reflects increased contrast. The simulator
  # is deleted after this attempt, so no user or later-test state is retained.
  xcrun simctl ui "$simulator_id" increase_contrast enabled
  contrast_state=$(xcrun simctl ui "$simulator_id" increase_contrast)
  if [[ "$contrast_state" != "enabled" ]]; then
    echo "Simulator did not enable Increase Contrast: $contrast_state" >&2
    exit 1
  fi

  result_bundle="$RESULT_ROOT/attempt-${attempt}.xcresult"
  raw_log="$RESULT_ROOT/attempt-${attempt}.log"
  compact_summary="$RESULT_ROOT/attempt-${attempt}-summary.json"
  text_summary="$RESULT_ROOT/attempt-${attempt}-summary.txt"
  rm -rf "$result_bundle"

  test_started=$SECONDS
  set +e
  test_command=(
    xcodebuild test-without-building
    -quiet
    -xctestrun "$XCTESTRUN"
    -destination "platform=iOS Simulator,id=$simulator_id"
    -resultBundlePath "$result_bundle"
    -parallel-testing-enabled YES
    -maximum-parallel-testing-workers "$PARALLEL_WORKERS"
    CODE_SIGNING_ALLOWED=NO
  )
  if [[ ${#TEST_ARGUMENTS[@]} -gt 0 ]]; then
    test_command+=("${TEST_ARGUMENTS[@]}")
  fi
  "${test_command[@]}" 2>&1 | tee "$raw_log"
  status=${PIPESTATUS[0]}
  set -e
  test_seconds=$((SECONDS - test_started))

  total_tests="unknown"
  if [[ -d "$result_bundle" ]] && xcrun xcresulttool get test-results summary \
      --path "$result_bundle" --compact > "$compact_summary"; then
    total_tests=$(jq -r '.totalTestCount' "$compact_summary")
    jq -r '
      "result=\(.result) tests=\(.totalTestCount) passed=\(.passedTests) failed=\(.failedTests) skipped=\(.skippedTests)",
      ([.testFailures] | flatten | .[]? | select(type == "object")
       | "failure=\(.testName): \(.failureText)")
    ' "$compact_summary" > "$text_summary"
  else
    printf 'result=unknown tests=unknown\n' > "$text_summary"
  fi

  echo "iOS UI timing: shard=$SHARD_ID device=$DEVICE workers=$PARALLEL_WORKERS attempt=$attempt test=${test_seconds}s total_tests=$total_tests"
  cat "$text_summary"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### iOS UI — $SHARD_ID — $DEVICE — attempt $attempt"
      echo
      echo "- Test runtime: ${test_seconds}s"
      echo "- Maximum parallel workers: $PARALLEL_WORKERS"
      echo "- Provisioning and test time: $((SECONDS - TOTAL_STARTED))s"
      echo "- Tests recorded: $total_tests"
      echo '```text'
      cat "$text_summary"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true

  if [[ $status -eq 0 && $EXPECTED_TESTS -gt 0 && "$total_tests" != "$EXPECTED_TESTS" ]]; then
    echo "Expected $EXPECTED_TESTS selected iOS UI tests, but XCTest recorded $total_tests." >&2
    status=1
  fi
  if [[ $status -eq 0 ]]; then
    echo "iOS UI total timing: shard=$SHARD_ID device=$DEVICE total=$((SECONDS - TOTAL_STARTED))s attempts=$attempt"
    exit 0
  fi
  if [[ $attempt -eq 1 && "$total_tests" == "0" ]]; then
    echo "No test started; retrying once with a newly provisioned simulator." >&2
    attempt=$((attempt + 1))
    continue
  fi

  echo "iOS UI tests failed; assertion, app, and accessibility failures are never retried." >&2
  exit "$status"
done

exit 1
