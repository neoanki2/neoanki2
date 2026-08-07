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

echo "==> Architecture boundaries"
bash "$ROOT/Scripts/validate-architecture.sh"

echo "==> Documentation coverage and links"
swift "$ROOT/Scripts/validate-docs.swift"

echo "All fast tests passed."
