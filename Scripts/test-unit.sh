#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  echo "Usage: Scripts/test-unit.sh [app|core|tooling|chrome] [--skip-build]"
}

lane="${1:-all}"
skip_build="${2:-}"
case "$lane" in
  --help|-h) usage; exit 0 ;;
  all|app|core|tooling|chrome) ;;
  *) usage >&2; exit 2 ;;
esac
if [[ $# -gt 2 || ( -n "$skip_build" && ( "$skip_build" != --skip-build || ! "$lane" =~ ^(app|core)$ ) ) ]]; then
  usage >&2
  exit 2
fi

build_root="${NEOANKI_UNIT_BUILD_ROOT:-$ROOT/.build}"

run_swift() {
  local package="$1" path="$2" filter="$3"
  shift 3
  local build_flags=(--disable-index-store)
  if [[ "$skip_build" == --skip-build ]]; then
    build_flags=(--skip-build)
  fi
  swift test --parallel "${build_flags[@]}" \
    --package-path "$path" --scratch-path "$build_root/ci-unit-$package" \
    --filter "$filter" "$@"
}

app() {
  # Keep the focused sync regressions. The two generated campaigns run in extended validation.
  run_swift app . . --skip 'generatedFaultCampaign|randomizedThreeDeviceConvergence'
}

core() {
  run_swift core NeoAnkiCore 'NeoAnkiCoreTests|NeoAnkiFSRSTests'
}

chrome() {
  cd Extensions/Chrome
  node --test tests/unit.test.js
}

python_suites() {
  local suite
  for suite in "$@"; do
    python3 "Scripts/test-$suite.py"
  done
}

tooling_release() {
  python_suites release deploy-iphone release-ios release-macos-app-store \
    macos-signing macos-testflight review-macos-app
  bash Scripts/test-release-workflow-reconciliation.sh
  bash Scripts/test-github-read-retry.sh
}

tooling_ios() {
  python_suites ios-ui-runner ios-ui-retry ios-runtime-selection ios-test-services \
    ios-background-refresh ios-app-icon-badge
}

tooling_checks() {
  python_suites sync-test-sensitivity editor-test-sensitivity editor-save-ui \
    performance-runner validate-architecture
  python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
}

run_parallel() {
  local log_dir job index status=0
  local jobs=("$@") pids=()
  mkdir -p "$build_root/unit-test-logs"
  log_dir="$(mktemp -d "$build_root/unit-test-logs/run.XXXXXX")"
  echo "Running ${jobs[*]} in parallel. Logs: $log_dir"
  for job in "${jobs[@]}"; do
    ( "$job" ) > "$log_dir/$job.log" 2>&1 &
    pids+=("$!")
  done
  for index in "${!jobs[@]}"; do
    job="${jobs[$index]}"
    if wait "${pids[$index]}"; then
      echo "$job passed."
    else
      status=1
      echo "$job failed. See $log_dir/$job.log." >&2
      cat "$log_dir/$job.log" >&2
    fi
  done
  return "$status"
}

tooling() {
  run_parallel tooling_release tooling_ios tooling_checks
}

if [[ "$lane" == all ]]; then
  run_parallel app core tooling chrome
else
  "$lane"
fi
