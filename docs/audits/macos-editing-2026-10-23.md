---
title: macOS editing and interaction audit
description: Source-backed findings, shared editing fixes, regression evidence, and desktop verification limits.
audience: developer
parent: Developer Guide
---

# macOS editing and interaction audit

The October 23, 2026 audit follows the existing native, calm design. Its focus is
reliable keyboard input, editing, draft safety, validation, and usable forms.
It does not certify live VoiceOver behavior or visual appearance: repository
desktop isolation prohibits opening, controlling, or capturing the Mac UI.

## Findings and corrections

| Priority | Finding and impact | Correction |
| --- | --- | --- |
| P1 | The Study menu registered Space, grade digits, and Cmd+Z globally. These keys compete with ordinary typing and native undo in fields throughout the app. | Remove those key equivalents. One application-local router dispatches contextual shortcuts only in the owning window, outside text input and child sheets. Native focused controls retain unmodified keys. |
| P1 | Arrangement and recording shortcuts can compete with text navigation and commands while editing a study card. | Apply the same responder-aware routing to arrangement, playback, recording, and Edit Card shortcuts. |
| P1 | Poem/prose source editors are destroyed during preview navigation, losing native editing state. | Draft-owned editor sessions retain the native scroll view, selection, and independent undo history across preview. External source replacements are undoable and preserve a valid selection. |
| P1 | The custom cloze editor does not enable native undo. | Enable undo and retain native selection/navigation. Shared Edit menu commands prefer text history even when it is empty, preventing accidental grade or canvas undo. |
| P1 | Image-mask undo/redo and Delete compete with editing image descriptions and answer text. | Register canvas history and deletion as contextual actions; text responders always take priority. |
| P1 | Mac poem/prose Cancel and builder-back navigation discard entered work without warning; new item Cancel protects existing items only. | Share draft dismissal handling across builders and source editors, guard host navigation and interactive dismissal, and protect both new and existing item drafts. Busy drafts cannot be dismissed. |
| P2 | Builder preview accepts missing metadata/destination and delays useful feedback until import. | Validate before preview, retain source input, focus the relevant field, and expose errors to accessibility focus. |
| P2 | Poem summaries and previews repeatedly parse and plan identical input during view evaluation. | Cache parsing/planning when source/title changes and use a lazy preview stack. |
| P2 | Study and API settings constrain content to fixed frames, and API port Return does not submit. | Use minimum/ideal sizes and native scrolling; validate Return like Apply and guard state changes. |
| P2 | Bare native text surfaces and inconsistent field chrome make editor boundaries hard to recognize. | Use shared system-colored plain-text surfaces, readable insets, focus indication, native Find, wrapping and scrolling; apply rounded native fields throughout the Mac shell. |
| P2 | Custom AppKit editors do not explicitly honor SwiftUI's disabled state during saves. | Propagate the enabled environment to native editability and prevent editing while source changes are being saved. |

## Shared implementation contract

`NeoAnkiTextEditing` owns platform adapters, editing sessions, contextual shortcut
and undo dispatch, and draft-dismissal helpers. Domain and application layers
remain platform neutral; shared SwiftUI screens use the adapter without importing
AppKit. The iOS editor continues to use SwiftUI `TextEditor`.

Poem, prose, and vocabulary definitions use plain text. Native clipboard, spelling,
word selection/deletion, Find, and undo remain available. Automatic quote/dash
replacement and forced spelling correction are disabled for source text. Return
inserts a newline; Tab and Shift+Tab traverse form controls. Standard single-line
fields retain the system field editor. Input-method composition is not replaced
by a binding refresh.

Cmd+Z uses the active text editor or canvas history. On an unobstructed study
surface it undoes the last grade. Shift+Cmd+Z redoes editor/canvas changes.
Text with an empty history never falls through to another context. Submitting a
typed study answer releases its text focus so grading shortcuts become available.

## Surface coverage

The source pass covers library search/table/navigation; deck creation, rename,
settings and deletion; add/edit item and rich-text/cloze/media fields; all three
builders and poem/prose reconciliation; Item Type Studio and shared Card Setup;
image occlusion; study interactions and recordings; import/portable transfer;
saved responses; Study, Study Day, Local API, and iCloud settings.

Existing strengths are preserved: semantic fonts/colors, labeled media actions,
explicit destructive confirmations, Item Type Studio validation focus, native
search and tables, and the fixed study action footer. No new visual language,
content format, HTTP interface, or persistence migration is introduced.

## Verification

- `NeoAnkiTextEditingTests` exercises actual detached native editors, independent
  histories, Unicode/whitespace, preview remounts, external replacement and
  selection clamping, routing decisions, and clean/dirty/busy dismissal.
- Existing rich-text, cloze, study-command, builder, application, and domain tests
  cover adjacent behavior. The native editing suite is part of `test-fast.sh`.
- Run `swift build`, the focused builder/editing suites, `Scripts/test-fast.sh`,
  architecture validation, and documentation validation before publication.

Live event dispatch, complete keyboard journeys, light/dark/contrast rendering,
clipboard menu dispatch, and VoiceOver traversal require isolated hosted Mac UI verification. They remain
unverified locally; detached AppKit tests do not establish desktop acceptance.
No visual accessibility score is assigned without that evidence.

A detached native `NSTextView` clipboard probe returned `false` from
`writeSelection(to:types:)`, including with the unmodified AppKit text view;
unique pasteboard string reads/writes succeeded. This does not establish
clipboard menu behavior in a running window. No window was opened to extend
that check. Standard native copy/paste remains a hosted UI acceptance item.
