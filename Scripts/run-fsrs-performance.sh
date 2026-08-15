#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_ROOT="$PROJECT_ROOT/NeoAnkiCore"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FSRS release memory benchmarks currently require macOS /usr/bin/time -l." >&2
  exit 2
fi

swift build --package-path "$PACKAGE_ROOT" -c release --product neoanki-fsrs-benchmark
BIN_PATH="$(swift build --package-path "$PACKAGE_ROOT" -c release --show-bin-path)/neoanki-fsrs-benchmark"
PERF_TMP="$(mktemp -d -t neoanki-fsrs-perf)"
trap 'if [[ "$PERF_TMP" == /tmp/neoanki-fsrs-perf.* ]]; then rm -r -- "$PERF_TMP"; fi' EXIT

run_case() {
  local events="$1"
  local budget="$2"
  local metrics="$PERF_TMP/time-$events.txt"
  local output
  output="$(/usr/bin/time -l "$BIN_PATH" --events "$events" 2>"$metrics")"
  local seconds
  seconds="$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^seconds=/) { split($i, a, "="); print a[2] } }' <<<"$output")"
  local peak_bytes
  peak_bytes="$(awk '/maximum resident set size/ { print $1 }' "$metrics")"
  local peak_mib
  peak_mib="$(awk -v bytes="$peak_bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }')"
  printf 'FSRS_RELEASE events=%s seconds=%s peak_rss_mib=%s\n' "$events" "$seconds" "$peak_mib"
  awk -v actual="$seconds" -v limit="$budget" 'BEGIN { exit !(actual < limit) }'
  if [[ "$events" == "100000" ]]; then
    awk -v bytes="$peak_bytes" 'BEGIN { exit !(bytes < 150 * 1048576) }'
  fi
}

run_case 1000 1
run_case 10000 2
run_case 100000 20
