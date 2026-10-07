#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> NeoAnkiCore unit + flow tests"
cd "$ROOT/NeoAnkiCore"
swift test --parallel

echo "==> NeoAnki2 ViewModel tests"
cd "$ROOT"
swift test --filter NeoAnki2Tests --skip AppLaunchSmokeTests --parallel

echo "==> Application and sync policy tests"
swift test --filter NeoAnkiApplicationTests --parallel

echo "==> Shared feature workflow tests"
swift test --filter NeoAnkiFeaturesTests --parallel

echo "==> Offline dictionaries and pack sync tests"
swift test --filter NeoAnkiVocabularyKitTests --parallel

echo "==> Local API registry and OpenAPI contract tests"
swift test --filter NeoAnkiAPITests --parallel

echo "==> Generated API reference"
swift run neoanki-api-reference check

echo "==> Architecture boundaries"
bash "$ROOT/Scripts/validate-architecture.sh"

echo "==> Spotlight-safe Xcode build paths"
bash "$ROOT/Scripts/validate-xcode-build-paths.sh"

echo "==> Mac release signing policy"
python3 "$ROOT/Scripts/test-macos-signing.py"

echo "==> Release workflow reconciliation"
bash "$ROOT/Scripts/test-release-workflow-reconciliation.sh"

echo "==> iOS UI infrastructure retry policy"
python3 "$ROOT/Scripts/test-ios-ui-retry.py"

echo "==> iOS background refresh executor isolation"
python3 "$ROOT/Scripts/test-ios-background-refresh.py"

echo "==> Mac and iOS app icon badge permission and refresh ordering"
python3 "$ROOT/Scripts/test-ios-app-icon-badge.py"

echo "==> Documentation coverage and links"
swift "$ROOT/Scripts/validate-docs.swift"

echo "All fast tests passed."
