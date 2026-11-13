---
version: 1
slug: "sources-neoankisharedui-learnincontextview-swift"
primary_target: "Sources/NeoAnkiSharedUI/LearnInContextView.swift"
related_targets: ["Sources/NeoAnkiFeatures/LearnInContextModel.swift", "Sources/NeoAnkiSharedUI/ContextAuthoringEntry.swift", "Sources/NeoAnkiIOS/MobileRootView.swift", "Sources/NeoAnki2/ContentView.swift"]
---

Mode: Operate. The learner chooses a deck, enters a word or phrase, previews
examples, and adds the cards. These are the only two inputs. Preserve the native
system typography, semantic colors, keyboard access, and compact-screen behavior.

Language, per-sentence meanings, target spans, and speech are automatic. No meaning
picker, editor, word-marking grid, source setup, language selector, or practice
configuration appears in this flow. The user explicitly removed those obstacles.
Saved cards remain editable through the ordinary item editor.

Use one content column with sentences, read-only contextual meanings, quiet
provenance, and playback. Find Examples stays directly below the input; Add Cards
appears in the fixed footer after examples arrive. Keyboard dismissal must not
move the Find action during a tap. Every request visibly progresses to examples
or an actionable error.
Successful save announces the destination, restores input focus, and offers Undo.

Generation stays Apple-only and local. Unsupported languages use installed local
examples; absent resources produce a clear error. Preserve existing saved cards
and their schedules. Verify headlessly and with disposable Simulator XCTest.
