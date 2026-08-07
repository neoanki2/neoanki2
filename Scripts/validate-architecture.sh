#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0

reject_imports() {
  local directory="$1"
  local expression="$2"
  local description="$3"
  local matches
  matches=$(rg -n "^import ($expression)$" "$ROOT/$directory" || true)
  if [ -n "$matches" ]; then
    echo "Architecture violation: $description" >&2
    echo "$matches" >&2
    FAILURES=1
  fi
}

reject_imports "Sources/NeoAnkiApplication" "SwiftUI|AppKit|UIKit|CloudKit" \
  "NeoAnkiApplication must remain platform and UI neutral."
reject_imports "Sources/NeoAnkiSharedUI" "AppKit|UIKit|CloudKit" \
  "NeoAnkiSharedUI must use shared SwiftUI APIs and explicit adapters."
reject_imports "Sources/NeoAnkiCloudSync" "SwiftUI|AppKit|UIKit" \
  "NeoAnkiCloudSync cannot own presentation code."
reject_imports "Sources/NeoAnkiDeckBuilderCore" "SwiftUI|AppKit|UIKit" \
  "Deck-builder contracts cannot depend on UI type erasure."
reject_imports "NeoAnkiCore/Sources/NeoAnkiCore" "SwiftUI|AppKit|UIKit|CloudKit" \
  "NeoAnkiCore cannot depend on UI or cloud transports."

if rg -n "@State private var is(AddingItem|ManagingTemplates|Studying|Browsing|ShowingImport|ShowingDeckBuilder|ShowingVocabularyPacks|AddingFromVocabulary)" \
  "$ROOT/Sources/NeoAnki2/ContentView.swift" >/dev/null; then
  echo "Architecture violation: ContentView navigation must use AppSession." >&2
  FAILURES=1
fi

if rg -n "ItemStore" "$ROOT/Sources/NeoAnkiApplication" \
  --glob '!LibraryRepository.swift' >/dev/null; then
  echo "Architecture violation: only SQLiteLibraryRepository may mention ItemStore in Application." >&2
  FAILURES=1
fi

if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi

echo "Architecture boundaries passed."
