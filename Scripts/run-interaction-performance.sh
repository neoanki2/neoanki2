#!/usr/bin/env bash
set -euo pipefail

# Per-interaction timings (one user action per measurement).
# Usage: NEOANKI_PERF_SCALE=large ./Scripts/run-interaction-performance.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCALE="${NEOANKI_PERF_SCALE:-large}"
OUTPUT="${NEOANKI_PERF_OUTPUT:-$ROOT/.performance/interactions-${SCALE}.ndjson}"

export NEOANKI_RUN_PERFORMANCE_TESTS=1
export NEOANKI_PERF_SCALE="$SCALE"
export NEOANKI_PERF_ALLOW_SLOW=1
export NEOANKI_REPO_ROOT="$ROOT"
export NEOANKI_PERF_JSON="$OUTPUT"

mkdir -p "$(dirname "$OUTPUT")"
: >"$OUTPUT"

echo "==> User interaction performance (scale=$SCALE, one action per test)"
cd "$ROOT"
swift test --filter 'UserInteractionPerformance'

echo "Results: $OUTPUT"
"$ROOT/Scripts/summarize-performance.sh" "$OUTPUT"
