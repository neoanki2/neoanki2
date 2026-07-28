#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCALE="${NEOANKI_PERF_SCALE:-small}"
INPUT="${1:-$ROOT/.performance/baseline-${SCALE}.ndjson}"

if [[ ! -f "$INPUT" ]]; then
  echo "Missing baseline file: $INPUT" >&2
  exit 1
fi

python3 - "$INPUT" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
rows = []
for line in path.read_text().splitlines():
    line = line.strip()
    if not line:
        continue
    rows.append(json.loads(line))

rows.sort(key=lambda row: row.get("durationSeconds", 0), reverse=True)

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
