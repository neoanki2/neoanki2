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

mkdir -p "$DESTINATION"
for screenshot in "${EXPECTED[@]}"; do
  cp "$SOURCE_DIR/$screenshot" "$DESTINATION/$screenshot"
done

echo "Promoted ${#EXPECTED[@]} reviewed screenshots into docs/assets/screenshots"
