#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/.build/documentation-screenshots}"

mkdir -p "$OUTPUT_DIR"
export DOC_SCREENSHOT_DIR="$OUTPUT_DIR"
export NEOANKI_UI_ONLY_TESTING="NeoAnki2UITests/DocumentationScreenshotTests"

"$ROOT/Scripts/run-ui-tests.sh"

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

echo "Captured ${#EXPECTED[@]} documentation screenshots in $OUTPUT_DIR"
