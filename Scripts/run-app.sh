#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:-app}"

case "$MODE" in
  app)
    "$ROOT/Scripts/build-test-app.sh"
    echo "Launching NeoAnki2..."
    open "$ROOT/.build/NeoAnki2.app"
    ;;
  cli)
    echo "Building NeoAnki2..."
    swift build -c debug
    echo "Running NeoAnki2..."
    exec swift run NeoAnki2
    ;;
  *)
    echo "Usage: $0 [app|cli]" >&2
    echo "  app  Build .app bundle and open it (default)" >&2
    echo "  cli  Build and run from terminal (swift run)" >&2
    exit 1
    ;;
esac
