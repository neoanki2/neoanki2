#!/usr/bin/env bash
set -euo pipefail

# Extended perf baselines (large / stress). Not bounded to five minutes.
# Usage: NEOANKI_PERF_SCALE=large|stress ./Scripts/run-performance-tests-slow.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCALE="${NEOANKI_PERF_SCALE:-large}"

if [[ "$SCALE" != "large" && "$SCALE" != "stress" ]]; then
  echo "Slow perf suite requires NEOANKI_PERF_SCALE=large or stress (got: $SCALE)" >&2
  exit 1
fi

OUTPUT="${NEOANKI_PERF_OUTPUT:-$ROOT/.performance/baseline-${SCALE}.ndjson}"

export NEOANKI_RUN_PERFORMANCE_TESTS=1
export NEOANKI_PERF_SCALE="$SCALE"
export NEOANKI_PERF_ALLOW_SLOW=1
export NEOANKI_REPO_ROOT="$ROOT"
export NEOANKI_PERF_JSON="$OUTPUT"

mkdir -p "$(dirname "$OUTPUT")"
: >"$OUTPUT"

echo "==> NeoAnkiCore user-flow performance tests (scale=$SCALE, no time cap)"
cd "$ROOT/NeoAnkiCore"
swift test --filter 'UserFlowPerformance'

echo "==> NeoAnki2 ViewModel performance tests (scale=$SCALE)"
cd "$ROOT"
swift test --filter 'UserFlowPerformance'

echo "Performance baseline written to $OUTPUT"
"$ROOT/Scripts/summarize-performance.sh" "$OUTPUT"
