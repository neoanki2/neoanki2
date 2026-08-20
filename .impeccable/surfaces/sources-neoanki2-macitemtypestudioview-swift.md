---
version: 1
slug: "sources-neoanki2-macitemtypestudioview-swift"
primary_target: "Sources/NeoAnki2/MacItemTypeStudioView.swift"
related_targets: ["Sources/NeoAnki2/TemplatesView.swift","Sources/NeoAnkiSharedUI/CardSetupEditorView.swift"]
---

# Surface brief: Preview-first Item Type Studio

Visitor mode: **Create and configure**. The user is shaping a card while keeping
the result continuously visible. Direct manipulation, spatial continuity, and
native macOS behavior outrank form density.

## 1. Job and audience

A learner or deck author edits an item type's fields and card setups. They need
to understand what each card will look like while changing its sources,
placement, reveal behavior, and advanced generation rules.

## 2. Outcome and proof

- Entering Studio replaces the outer Item Types navigator with the editing
  workspace and keeps the card canvas visible without vertical scrolling.
- Clicking content on the card selects it and makes its complete configuration
  available in the inspector; empty regions remain direct Add targets.
- Save or Cancel restores the navigator and its prior selection.
- A 1024-point documentation window shows rail and canvas together; narrower
  editor widths keep that pairing and present the inspector as a labeled sheet.

## 3. Selected direction

Preserve NeoAnki2's native Quiet Desk language. The structural thesis is
**the card is the editor**: a compact left rail manages the item type, setups,
and fields; the canvas owns the visual hierarchy; the inspector handles the
selected content and lower-frequency setup or Advanced properties.

## 4. Scope and boundaries

In scope: macOS Item Type Studio topology, reusable shared canvas/inspector
composition, selection behavior, responsive inspector presentation,
accessibility, UI tests, guidance, and screenshots.

Untouched: the draft domain, persistence schema, external APIs, deterministic
fixtures, validation rules, legacy placement compatibility, and the stacked
iPhone/iPad presentation.

## 5. States and ranges

- No selected content, selected content, and an empty addable hole.
- Prompt versus revealed answer.
- Inspector persistent at wide widths and sheet-based at narrow widths.
- Validation errors route focus to the relevant rail, canvas selection, or
  inspector control.
- One or many fields and card setups share a single rail scroll context.
- Reduce Motion disables nonessential reveal animation.

## 6. Interaction and layout

Visual and accessibility order is rail, canvas, inspector. The rail orders item
type name, Card setups, then Fields. The canvas stays non-scrolling and receives
the dominant share of the viewport. Its toolbar keeps Add content, layout,
Show/Hide Answer, and Inspector adjacent to the card. Inspector content may
scroll independently.

Canvas selection is persistent, visibly highlighted, and exposes source,
reveal, playback, placement, ordering, duplicate, and remove actions. All icon
actions have at least a 44-point target. Avoid cross-region accessibility sort
priorities; source order defines traversal.

## 7. Constraints

- Never reveal the outer Item Types navigator while a Studio draft is active.
- Never let a narrow window remove the card canvas.
- Preserve semantic system colors, Dynamic Type, keyboard shortcuts, VoiceOver
  traits, destructive confirmations, Save/Cancel semantics, and native sheet
  behavior.
- The shared editor defaults to stacked presentation; macOS opts into workspace.
