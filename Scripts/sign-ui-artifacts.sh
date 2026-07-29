#!/usr/bin/env bash
# Sign only our app-under-test. Never deep-sign NeoAnki2UITests-Runner (breaks Apple frameworks).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/UITests/AppBundle/NeoAnki2.entitlements"

sign_app_bundle() {
  local app_path="$1"
  if [[ ! -d "$app_path" ]]; then
    return 0
  fi

  xattr -cr "$app_path" 2>/dev/null || true

  local executable="$app_path/Contents/MacOS/NeoAnki2"
  if [[ -f "$executable" ]]; then
    codesign --force --sign - --timestamp=none \
      --entitlements "$ENTITLEMENTS" \
      "$executable"
  fi

  codesign --force --sign - --timestamp=none \
    --entitlements "$ENTITLEMENTS" \
    "$app_path"
}

sign_app_bundle "$ROOT/.build/NeoAnki2.app"

DERIVED_ROOT="${NEOANKI_UI_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"
while IFS= read -r products_dir; do
  sign_app_bundle "$products_dir/NeoAnki2.app"
done < <(find "$DERIVED_ROOT" -maxdepth 4 -type d -name Products 2>/dev/null | sort -u)

echo "Signed NeoAnki2.app bundles (left XCTest runner untouched)."
