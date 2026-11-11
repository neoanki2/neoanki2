#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> NeoAnkiCore unit + flow tests"
cd "$ROOT/NeoAnkiCore"
swift test --parallel

echo "==> All root-package headless tests"
cd "$ROOT"
swift test --parallel

echo "==> Generated API reference"
swift run neoanki-api-reference check

echo "==> Architecture boundaries"
python3 "$ROOT/Scripts/test-validate-architecture.py"
bash "$ROOT/Scripts/validate-architecture.sh"

echo "==> Spotlight-safe Xcode build paths"
bash "$ROOT/Scripts/validate-xcode-build-paths.sh"

echo "==> Unified release contracts"
python3 "$ROOT/Scripts/test-release.py"

echo "==> Mac release signing policy"
python3 "$ROOT/Scripts/test-macos-signing.py"

echo "==> Apple TestFlight candidate integrity"
python3 "$ROOT/Scripts/test-macos-testflight.py"
python3 "$ROOT/Scripts/test-review-macos-app.py"

echo "==> Release workflow reconciliation"
bash "$ROOT/Scripts/test-release-workflow-reconciliation.sh"

echo "==> GitHub read retry response isolation"
bash "$ROOT/Scripts/test-github-read-retry.sh"

echo "==> iOS XCTest service readiness policy"
python3 "$ROOT/Scripts/test-ios-test-services.py"
python3 "$ROOT/Scripts/test-ios-runtime-selection.py"

echo "==> iOS UI infrastructure retry policy"
python3 "$ROOT/Scripts/test-ios-ui-retry.py"
python3 "$ROOT/Scripts/test-ios-ui-runner.py"

echo "==> iOS background refresh executor isolation"
python3 "$ROOT/Scripts/test-ios-background-refresh.py"

echo "==> Mac and iOS app icon badge permission and refresh ordering"
python3 "$ROOT/Scripts/test-ios-app-icon-badge.py"

echo "==> Documentation coverage and links"
swift "$ROOT/Scripts/validate-docs.swift"

echo "All fast tests passed."
