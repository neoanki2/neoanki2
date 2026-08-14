#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_PREFIX="$ROOT/.build/xcode-products/"

check_project() {
  local project="$1"
  local scheme="$2"
  local build_dir

  build_dir=$(
    xcodebuild \
      -project "$ROOT/$project" \
      -scheme "$scheme" \
      -showBuildSettings 2>/dev/null \
      | awk -F ' = ' '/^[[:space:]]*BUILD_DIR = / { print $2; exit }'
  )

  case "$build_dir/" in
    "$EXPECTED_PREFIX"*) ;;
    *)
      echo "$project puts build products outside the hidden .build directory: $build_dir" >&2
      exit 1
      ;;
  esac
}

check_project "Xcode/NeoAnkiMac.xcodeproj" "NeoAnkiMac"
check_project "UITests/NeoAnki2UITests.xcodeproj" "NeoAnki2UITests"

echo "Xcode build products stay under .build/xcode-products."
