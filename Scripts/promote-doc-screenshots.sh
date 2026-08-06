#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="${1:-}"
DESTINATION="$ROOT/docs/assets/screenshots"

if [[ -z "$SOURCE_DIR" || ! -d "$SOURCE_DIR" ]]; then
  echo "Usage: $0 <reviewed-screenshot-directory>" >&2
  exit 2
fi

EXPECTED=(
  library-empty.png library-populated.png decks-nested.png item-add.png
  item-rich-text.png item-media.png item-detail.png study-prompt.png
  study-answer.png study-type.png study-grade-help.png study-complete.png
  item-types.png template-editor.png template-advanced.png import-sheet.png
  portable-conflict.png scheduling-result.png error-startup.png
)

for screenshot in "${EXPECTED[@]}"; do
  if [[ ! -s "$SOURCE_DIR/$screenshot" ]]; then
    echo "Reviewed artifact is missing $screenshot" >&2
    exit 1
  fi
done

python3 - "$SOURCE_DIR" "${EXPECTED[@]}" <<'PY'
import datetime
import hashlib
import json
import pathlib
import re
import struct
import sys

directory = pathlib.Path(sys.argv[1])
expected_files = set(sys.argv[2:])
manifest_path = directory / "manifest.json"

try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"Reviewed artifact has an invalid or missing screenshot manifest: {error}")

if manifest.get("schemaVersion") != 1:
    raise SystemExit("Reviewed screenshot manifest must use schemaVersion 1")
if manifest.get("appearance") != "dark":
    raise SystemExit("Reviewed screenshot manifest appearance must be dark")
if re.fullmatch(r"[0-9a-f]{40}", manifest.get("sourceSHA") or "") is None:
    raise SystemExit("Reviewed screenshot manifest has an invalid sourceSHA")
try:
    datetime.datetime.strptime(manifest.get("capturedAt"), "%Y-%m-%dT%H:%M:%SZ")
except (TypeError, ValueError):
    raise SystemExit("Reviewed screenshot manifest capturedAt must be a UTC RFC3339 timestamp")

entries = manifest.get("screenshots")
if not isinstance(entries, list):
    raise SystemExit("Reviewed screenshot manifest screenshots must be an array")
by_filename = {entry.get("filename"): entry for entry in entries if isinstance(entry, dict)}
if set(by_filename) != expected_files or len(entries) != len(expected_files):
    raise SystemExit("Reviewed screenshot manifest entries do not exactly match the expected screenshots")

for filename in sorted(expected_files):
    entry = by_filename[filename]
    path = directory / filename
    with path.open("rb") as image:
        header = image.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{filename} is not a valid PNG")
    width, height = struct.unpack(">II", header[16:24])
    if entry.get("width") != width or entry.get("height") != height or width < 1200 or height < 760:
        raise SystemExit(f"Manifest dimensions do not match {filename}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if entry.get("sha256") != digest:
        raise SystemExit(f"Manifest SHA-256 does not match {filename}")
    if not isinstance(entry.get("scenario"), str) or not entry["scenario"].strip():
        raise SystemExit(f"Manifest scenario is missing for {filename}")
    identifiers = entry.get("expectedVisibleIdentifiers")
    if (
        not isinstance(identifiers, list)
        or not identifiers
        or any(not isinstance(value, str) or not value.strip() for value in identifiers)
    ):
        raise SystemExit(f"Expected visible identifiers are missing for {filename}")
PY

mkdir -p "$DESTINATION"
for screenshot in "${EXPECTED[@]}"; do
  cp "$SOURCE_DIR/$screenshot" "$DESTINATION/$screenshot"
done
cp "$SOURCE_DIR/manifest.json" "$DESTINATION/manifest.json"

echo "Promoted ${#EXPECTED[@]} reviewed screenshots and validated metadata into docs/assets/screenshots"
