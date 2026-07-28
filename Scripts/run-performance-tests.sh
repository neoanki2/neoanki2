#!/usr/bin/env bash
set -euo pipefail

# Full user-flow perf baseline: ≤5 minutes total wall time (small scale only).
# For large/stress runs use: ./Scripts/run-performance-tests-slow.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCALE="small"
OUTPUT="${NEOANKI_PERF_OUTPUT:-$ROOT/.performance/baseline-${SCALE}.ndjson}"
SUITE_BUDGET_SECONDS="${NEOANKI_PERF_SUITE_BUDGET_SECONDS:-300}"

if [[ "${NEOANKI_PERF_SCALE:-small}" != "small" ]]; then
  echo "Note: ignoring NEOANKI_PERF_SCALE=${NEOANKI_PERF_SCALE:-}; fast suite always uses scale=small." >&2
  echo "For large/stress baselines run: ./Scripts/run-performance-tests-slow.sh" >&2
fi

export NEOANKI_RUN_PERFORMANCE_TESTS=1
export NEOANKI_PERF_SCALE="$SCALE"
export NEOANKI_REPO_ROOT="$ROOT"
export NEOANKI_PERF_JSON="$OUTPUT"

mkdir -p "$(dirname "$OUTPUT")"
: >"$OUTPUT"

run_suite() {
  echo "==> NeoAnkiCore user-flow performance tests (scale=$SCALE, budget=${SUITE_BUDGET_SECONDS}s total)"
  cd "$ROOT/NeoAnkiCore"
  swift test --filter 'UserFlowPerformance'

  echo "==> NeoAnki2 ViewModel performance tests (scale=$SCALE)"
  cd "$ROOT"
  swift test --filter 'UserFlowPerformance'
}

if command -v timeout >/dev/null 2>&1; then
  timeout "${SUITE_BUDGET_SECONDS}" bash -c "$(declare -f run_suite); run_suite"
else
  run_suite
fi

echo "Performance baseline written to $OUTPUT"
"$ROOT/Scripts/summarize-performance.sh" "$OUTPUT"
