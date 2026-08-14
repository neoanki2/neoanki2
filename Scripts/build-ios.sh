#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
SDK="${SDK:-iphonesimulator}"
ARCH="${ARCH:-arm64}"
PLATFORM_NAME="iphonesimulator"
if [[ "$SDK" == "iphoneos" ]]; then PLATFORM_NAME="iphoneos"; fi

DERIVED_DATA="$ROOT/.build/xcode-products/NeoAnkiiOS"
PACKAGE_MODULES="$DERIVED_DATA/Build/Products/$CONFIGURATION-$PLATFORM_NAME $ROOT/build/$CONFIGURATION-$PLATFORM_NAME $ROOT/NeoAnkiCore/build/$CONFIGURATION-$PLATFORM_NAME"
extra_settings=()
if [[ "${NEOANKI_SKIP_ASSETS:-0}" == "1" ]]; then
  extra_settings+=(EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets)
fi

common=(
  -project "$ROOT/Xcode/NeoAnkiiOS.xcodeproj"
  -configuration "$CONFIGURATION"
  -sdk "$SDK"
  -arch "$ARCH"
  CODE_SIGNING_ALLOWED=NO
  SWIFT_ENABLE_EXPLICIT_MODULES=NO
  SWIFT_INCLUDE_PATHS="$PACKAGE_MODULES"
  "${extra_settings[@]}"
)

if [[ "${NEOANKI_SKIP_ASSETS:-0}" == "1" ]]; then
  # A target build remains available on command-line-only Xcode installations
  # that have the SDK but no installed Simulator runtime.
  xcodebuild "${common[@]}" -target NeoAnkiiOS build
else
  xcodebuild "${common[@]}" -scheme NeoAnkiiOS -derivedDataPath "$DERIVED_DATA" build
fi
