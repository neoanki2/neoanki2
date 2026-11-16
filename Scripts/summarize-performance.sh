#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCALE="${NEOANKI_PERF_SCALE:-small}"
INPUT="${1:-$ROOT/.performance/baseline-${SCALE}.ndjson}"

if [[ ! -f "$INPUT" ]]; then
  echo "Missing baseline file: $INPUT" >&2
  exit 1
fi

python3 - "$INPUT" "${@:2}" <<'PY'
import json
import math
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = []
for line in path.read_text().splitlines():
    line = line.strip()
    if not line:
        continue
    rows.append(json.loads(line))

if not rows:
    raise SystemExit("Performance baseline has no measurements.")
missing = set(sys.argv[2:]) - {row.get("layer") for row in rows}
if missing:
    raise SystemExit("Performance baseline is missing layers: " + ", ".join(sorted(missing)))
for row in rows:
    duration = row.get("durationSeconds")
    if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration < 0:
        raise SystemExit("Performance baseline has an invalid duration.")
rows.sort(key=lambda row: row["durationSeconds"], reverse=True)

print(f"Performance summary ({len(rows)} flows) — slowest first\n")
print(f"{'Rank':<5} {'Duration':>10}  {'Layer':<5}  Flow")
print("-" * 72)
for index, row in enumerate(rows, start=1):
    duration = row.get("durationSeconds", 0)
    layer = row.get("layer", "?")
    flow = row.get("flow", "?")
    scale = row.get("scale", "?")
    print(f"{index:<5} {duration:>9.3f}s  {layer:<5}  {flow}  [{scale}]")

if rows:
    total = sum(row.get("durationSeconds", 0) for row in rows)
    print("-" * 72)
    print(f"Total measured time: {total:.1f}s")
    print(f"Slowest: {rows[0]['flow']} ({rows[0]['durationSeconds']:.3f}s)")
PY
