#!/usr/bin/env bash
set -euo pipefail

if ! command -v rg >/dev/null 2>&1; then
  echo "Architecture validation requires ripgrep (rg); install it before running this gate." >&2
  exit 127
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0

reject_matches() {
  local description="$1"
  shift
  local matches status=0
  matches=$(rg -n "$@") || status=$?
  case "$status" in
    0)
      echo "Architecture violation: $description" >&2
      echo "$matches" >&2
      FAILURES=1
      ;;
    1) ;; # ripgrep distinguishes no matches from a failed scan.
    *)
      echo "Architecture validation could not scan: $description (rg exit $status)." >&2
      exit "$status"
      ;;
  esac
}

reject_imports() {
  reject_matches "$3" "^import ($2)$" "$ROOT/$1"
}

reject_imports "Sources/NeoAnkiApplication" "SwiftUI|AppKit|UIKit|CloudKit" \
  "NeoAnkiApplication must remain platform and UI neutral."
reject_imports "Sources/NeoAnkiFeatures" "SwiftUI|AppKit|UIKit|CloudKit" \
  "NeoAnkiFeatures must remain platform neutral."
reject_imports "Sources/NeoAnkiSharedUI" "AppKit|UIKit|CloudKit" \
  "NeoAnkiSharedUI must use shared SwiftUI APIs and explicit adapters."
reject_imports "Sources/NeoAnkiCloudSync" "SwiftUI|AppKit|UIKit" \
  "NeoAnkiCloudSync cannot own presentation code."
reject_imports "Sources/NeoAnkiDeckBuilderCore" "SwiftUI|AppKit|UIKit" \
  "Deck-builder contracts cannot depend on UI type erasure."
reject_imports "NeoAnkiCore/Sources/NeoAnkiCore" "SwiftUI|AppKit|UIKit|CloudKit" \
  "NeoAnkiCore cannot depend on UI or cloud transports."

reject_matches "ContentView navigation must use AppSession." \
  "@State private var is(AddingItem|ManagingTemplates|Studying|Browsing|ShowingImport|ShowingDeckBuilder|ShowingVocabularyPacks|AddingFromVocabulary)" \
  "$ROOT/Sources/NeoAnki2/ContentView.swift"

reject_matches "Only SQLite repository adapters may mention ItemStore in Application." \
  "ItemStore" "$ROOT/Sources/NeoAnkiApplication" \
  --glob '!LibraryRepository.swift' \
  --glob '!LocalAPILibrary.swift'

reject_matches "The HTTP adapter must depend on LocalAPILibrary, not SQLite persistence." \
  "ItemStore|SQLiteLibraryRepository" "$ROOT/Sources/NeoAnkiAPI"

reject_matches "UI features must receive application capabilities, not persistence." \
  "ItemStore|SQLiteLibraryRepository" "$ROOT/Sources/NeoAnki2" \
  --glob '!NeoAnki2App.swift'

reject_matches "Shared features and mobile UI must use repository capabilities." \
  "ItemStore|SQLiteLibraryRepository" "$ROOT/Sources/NeoAnkiFeatures" "$ROOT/Sources/NeoAnkiIOS"

reject_matches "The composition root must construct SQLiteLibraryRepository, not ItemStore." \
  "ItemStore" "$ROOT/Sources/NeoAnki2/NeoAnki2App.swift"

if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi

echo "Architecture boundaries passed."
