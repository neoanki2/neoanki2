#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/.build/documentation-screenshots}"

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR"/*.png "$OUTPUT_DIR/manifest.json" "$OUTPUT_DIR/.capture-context.json"
export DOC_SCREENSHOT_DIR="$OUTPUT_DIR"
export NEOANKI_UI_TEST_PLAN="DocumentationScreenshots"
DOC_SCREENSHOT_SOURCE_SHA="$(git -C "$ROOT" rev-parse HEAD)"
DOC_SCREENSHOT_CAPTURED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf '{"sourceSHA":"%s","capturedAt":"%s","appearance":"dark"}\n' \
  "$DOC_SCREENSHOT_SOURCE_SHA" "$DOC_SCREENSHOT_CAPTURED_AT" \
  > "$OUTPUT_DIR/.capture-context.json"
"$ROOT/Scripts/run-ui-tests.sh"
rm -f "$OUTPUT_DIR/.capture-context.json"

EXPECTED=(
  library-empty.png library-populated.png decks-nested.png item-add.png
  item-rich-text.png item-media.png item-detail.png study-prompt.png
  study-answer.png study-type.png study-grade-help.png study-complete.png
  item-types.png template-editor.png template-advanced.png import-sheet.png
  portable-conflict.png scheduling-result.png error-startup.png
)

for screenshot in "${EXPECTED[@]}"; do
  if [[ ! -s "$OUTPUT_DIR/$screenshot" ]]; then
    echo "Missing documentation screenshot: $screenshot" >&2
    exit 1
  fi
done

swift "$ROOT/Scripts/normalize-doc-screenshot-corners.swift" \
  "$OUTPUT_DIR" "${EXPECTED[@]}"

python3 - "$OUTPUT_DIR" "$DOC_SCREENSHOT_SOURCE_SHA" "${EXPECTED[@]}" <<'PY'
import datetime
import hashlib
import json
import pathlib
import re
import struct
import sys

directory = pathlib.Path(sys.argv[1])
expected_sha = sys.argv[2]
expected_files = set(sys.argv[3:])
manifest_path = directory / "manifest.json"

try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"Invalid or missing screenshot manifest: {error}")

if manifest.get("schemaVersion") != 1:
    raise SystemExit("Screenshot manifest must use schemaVersion 1")
if manifest.get("appearance") != "dark":
    raise SystemExit("Screenshot manifest appearance must be dark")
source_sha = manifest.get("sourceSHA")
if source_sha != expected_sha or re.fullmatch(r"[0-9a-f]{40}", source_sha or "") is None:
    raise SystemExit("Screenshot manifest sourceSHA is missing or does not match the captured commit")
captured_at = manifest.get("capturedAt")
try:
    datetime.datetime.strptime(captured_at, "%Y-%m-%dT%H:%M:%SZ")
except (TypeError, ValueError):
    raise SystemExit("Screenshot manifest capturedAt must be a UTC RFC3339 timestamp")

entries = manifest.get("screenshots")
if not isinstance(entries, list):
    raise SystemExit("Screenshot manifest screenshots must be an array")
by_filename = {entry.get("filename"): entry for entry in entries if isinstance(entry, dict)}
if set(by_filename) != expected_files or len(entries) != len(expected_files):
    raise SystemExit("Screenshot manifest entries do not exactly match the expected screenshots")

for filename in sorted(expected_files):
    entry = by_filename[filename]
    path = directory / filename
    with path.open("rb") as image:
        header = image.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{filename} is not a valid PNG")
    width, height = struct.unpack(">II", header[16:24])
    if entry.get("width") != width or entry.get("height") != height:
        raise SystemExit(f"Manifest dimensions do not match {filename}")
    if width < 1024 or height < 674:
        raise SystemExit(f"Documentation capture is too small: {filename} is {width}x{height}")
    if not isinstance(entry.get("scenario"), str) or not entry["scenario"].strip():
        raise SystemExit(f"Manifest scenario is missing for {filename}")
    identifiers = entry.get("expectedVisibleIdentifiers")
    if (
        not isinstance(identifiers, list)
        or not identifiers
        or any(not isinstance(value, str) or not value.strip() for value in identifiers)
    ):
        raise SystemExit(f"Expected visible identifiers are missing for {filename}")
    entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()

manifest_path.write_text(
    json.dumps(manifest, indent=2, sort_keys=True, separators=(",", " : ")) + "\n",
    encoding="utf-8",
)
PY

echo "Captured and validated ${#EXPECTED[@]} documentation screenshots in $OUTPUT_DIR"
echo "Manifest: $OUTPUT_DIR/manifest.json"
