---
version: 1
slug: "sources-neoankisharedui-wordcaptureview-swift"
primary_target: "Sources/NeoAnkiSharedUI/WordCaptureView.swift"
related_targets: ["Sources/NeoAnkiFeatures/WordCaptureModel.swift","Sources/NeoAnkiIOS/MobileRootView.swift","Sources/NeoAnki2/ContentView.swift"]
---

Mode: Operate. Audience: learners capturing one word or phrase from an installed offline dictionary.

Keep the native visual system. The stable header and toolbar hold pair controls, card setup, and the word input. At accessibility sizes and in short landscape layouts, the header scrolls with the content to preserve reachability. Results and required content scroll below; Add stays fixed above the mobile keyboard or at the Mac sheet bottom. Typed-word fields share the main input instead of duplicating it. Optional content stays under More details.

Save semantic mappings per library/dictionary/deck pair. Choosing a deck restores its last dictionary; choosing a dictionary keeps the deck. Separate pair setup from per-word edits. Prepare unique relevant values; ask only for required ambiguous content. Preserve user edits, Unicode, and required-field validation.

A successful save announces the destination, clears the draft, and refocuses the input for immediate continuation. No preview step, online lookup, or configuration sync. Mac uses File Add Word, CmdShiftN and CmdReturn; iPhone/iPad use Home/deck/Create actions. Desktop GUI verification is prohibited; use headless checks and disposable Simulator XCTest.
