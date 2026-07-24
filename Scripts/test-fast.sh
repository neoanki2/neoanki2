#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> NeoAnkiCore unit + flow tests"
cd "$ROOT/NeoAnkiCore"
swift test --parallel

echo "==> NeoAnki2 ViewModel tests"
cd "$ROOT"
swift test --filter NeoAnki2Tests --parallel

echo "All fast tests passed."
