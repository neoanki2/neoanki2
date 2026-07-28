---
target: Sources/NeoAnki2
total_score: 28
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
p1_closed: 3
timestamp: 2026-07-28T10-42-05Z
slug: sources-neoanki2
---
# NeoAnki2 Design Critique — Scope Home and Browse Mode

## Design Health Score

| # | Heuristic | Score | Δ | Key issue |
|---|---|---:|---:|---|
| 1 | Visibility of system status | 3 | — | Bulk move/delete loop with no in-flight feedback; `isLoading` only flips after the loop ends |
| 2 | Match between system and real world | 3 | +1 | Scheduler vocabulary reaches the learner: browse prints "Relearning" and "Lapses" unexplained |
| 3 | User control and freedom | 2 | −1 | Deleting a multi-selection is irreversible while grading one card has undo |
| 4 | Consistency and standards | 3 | +1 | Deck-first/item-first conflict resolved; File ▸ New restored (**closed**); window title still omits browse |
| 5 | Error prevention | 3 | — | Destructive guards are good; `Delete All` sits permanently on a routine landing surface |
| 6 | Recognition rather than recall | 3 | +1 | Item edit path exists; the Answer column's reveal was undiscoverable (**closed**, see below) |
| 7 | Flexibility and efficiency | 3 | −1 | Sorting and column customization are mouse-only; Move to Deck flattens the deck tree |
| 8 | Aesthetic and minimalist design | 3 | — | Six default browse columns, two effectively constant for the primary persona |
| 9 | Error recovery | 3 | — | Bulk operations return a success count that both call sites discard |
| 10 | Help and documentation | 2 | −1 | `GradeGuideView` explains grades and nothing else — no help for phase, lapses, or leeches |
| **Total** | | **28/40** | **±0** | **Good** |

The flat total is coincidence, not stagnation. Consistency and Match each rose a point because the
mental-model conflict that cost the 2026-07-25 baseline is genuinely resolved — the sidebar
navigates scopes, the detail pane defaults to a scope home rather than an enumeration, and
`docs/DESIGN.md` and `.impeccable/design.json` both say so. Browse mode then spent those points on
recall, help, and undo debt of its own.

## Design Specificity Verdict

**Authored, decisively, on the scope home. Category-default on the browse table's column set.**

The scope-home evidence would not survive being lifted into another product: a disabled Study button
replaced by a computed sentence about when memory will next need help; leech copy that argues
rewriting beats repeating; search that matches answer text while the Answer column ships hidden, so
a half-remembered answer finds an item without showing it; phase sorted by learning progression
rather than alphabetically. These are domain arguments expressed as code.

`ItemBrowserView` is a stock `Table` plus stock `.searchable` plus a stock multi-select toolbar.
Borrowed familiarity is correct for Operate mode and no expression is wanted there — but *which*
columns ship visible was the one place a product argument belonged, and shipping Type and Cards
(invariant for the primary persona) while Lapses renders blank on nearly every row inverts the
priority the surface brief set.

The deterministic scan returned zero findings because the target is Swift, outside the detector's
web/markup scan set. That is not evidence the native UI is clean; every finding here and in the
companion audit came from reading source against the design contract.

## Cognitive Load

**Four clear failures, two partial**, all on browse rather than the scope home:

- **Visual hierarchy** — the due headline was 17pt semibold against a 15pt semibold section label
  two blocks down (**closed**, see below).
- **Single focus / minimal choices** — browse presents six columns, a search field, and up to five
  toolbar controls at once; two of them are irrelevant to a selection just made. The Move to Deck
  menu is unbounded and flattened.
- **Working memory** — opening an item destroys the browse view, and selection state does not
  survive the round trip.
- **Progressive disclosure** — the intent (Answer hidden, browse as a deliberate mode) is
  exemplary; the disclosure *control* did not deliver it (**closed**, see below).

The scope home passes single focus, chunking, and one-thing-at-a-time cleanly.

## Emotional Journey

- **Peak:** selecting a scope and reading the due count with Study directly beneath it. One glance,
  one keystroke, no list to wade through.
- **End (strongest beat in the product):** a session closes with its own icon and an optional undo,
  then drops onto a scope home reading "You're caught up" plus when the next card returns. The app
  finishes by answering the question a spaced-repetition user actually has. Nothing celebratory,
  which honors the no-gamification commitment while still closing the loop.
- **Valley 1 — first run:** empty sidebar, a disabled Browse button, one empty state. Nothing
  mentions the `Basic` starter type that `docs/PRODUCT.md` documents. Deliberately deferred.
- **Valley 2 — deleting items:** the dialog tells the truth that deletion cannot be undone, while
  ⌘Z is globally bound to Undo Last Grade. The safety net is on the reversible action.
- **Valley 3 — the leech callout dead-ends:** the only pedagogical coaching in the product, in the
  quietest style on the page, with no route to the cards it describes even though browse has a
  Lapses column that would answer it.
- **Valley 4 — a confidently wrong sentence:** "Cards become due after their first review" is shown
  whenever `nextDueAt` is nil, including when every card in scope is suspended.

## Priority Issues

### [P1 — CLOSED] The focal moment was not focal
- **Why it mattered:** the surface brief required the due count to lead, and it sat 2pt above a
  subordinate section label and 4pt above sidebar chrome. The Study button was doing the hierarchy
  work the typography should have done.
- **Evidence:** `ScopeHomeView.swift:112`, `DesignSystem.swift:58-59`
- **Fixed by:** adding a `uiDisplay` token (`.title2` bold, monospaced digits) rather than an
  exception to The Card Type Scale Rule, which the plan's constraints forbid; demoting the "Cards"
  heading to a quiet group label; cutting the scope caption that duplicated the window title; and
  breaking the uniform 32pt rhythm so the headline block gets more air beneath it than the blocks
  below get between them. Both design sources record the token and the amended rule.

### [P1 — CLOSED] The Answer column was technically revealable and practically invisible
- **Why it mattered:** `docs/DESIGN.md` promised "hidden and user-revealable," but the only
  affordance was a right-click on a table header — no menu item, no keyboard route, and the reveal
  was discarded on every exit. A rule whose escape hatch nobody can find is an unexplained
  restriction, not a considered default.
- **Evidence:** `ItemBrowserView.swift:17, 22-26`, `ContentView.swift:352-360`
- **Fixed by:** `Library ▸ Show / Hide Answer Column` at ⌥⌘A, routed through the existing focused
  -value handler pattern, with the choice persisted in `@AppStorage` so it survives leaving browse.
  Header-menu changes write back to the same preference, so the two paths stay in agreement. Two UI
  tests cover the menu path and persistence; `AppPreferences.resetForTesting()` keeps the
  preference from leaking between UI test launches. Docs and the No Answers by Default Rule now
  describe the reveal path they promise.

### [P1 — CLOSED] Add Item had no menu item anywhere in the app
- **Why it mattered:** `CommandGroup(replacing: .newItem) {}` removed File ▸ New wholesale, so the
  app's second most common workflow existed only as a toolbar button with an undocumented ⌘N —
  while Import, Export, Build Deck, Browse, and Item Types all had menu homes. Menu navigation is
  the standard Mac discovery path and the only one available to VoiceOver menu users. Pre-existing,
  not introduced by this work.
- **Evidence:** `NeoAnki2App.swift:39`, `LibraryCommands.swift:34-75`
- **Fixed by:** `File ▸ New Item` at ⌘N, routed through a new `openAddItem` handler and gated the
  same way the toolbar button effectively was (`LibraryCommands.swift:39-49`,
  `ContentView.swift:210`, `:220-226`). The empty `.newItem` replacement is gone from
  `NeoAnki2App`. Duplicate shortcut owners resolved in the same pass: ⌥⌘B, ⌘⇧S, and ⌘N are now
  declared only on their menu commands, since that is where macOS displays them — the toolbar
  buttons keep their actions and lose their bindings. Covered by
  `testAddItemHasAMenuHomeUnderFile`. Docs record the File menu entry and no longer claim the
  standard New command is removed.

### [P2 — OPEN] Bulk operations have no undo, no progress, and no partial-result reporting
- **Why it matters:** the brief names "several thousand" items as the range browse must survive.
  `moveItems`/`deleteItems` loop one store round trip per id and only set `isLoading` after the loop,
  so a few hundred rows freeze the UI with no feedback. Both return a success count; both call
  sites discard it. Delete has strictly less recovery than grading one card.
- **Evidence:** `ItemsModel.swift:296-332`, `ItemBrowserView.swift:102, 241`
- **Fix:** one transaction, determinate progress through the toolbar `.status` slot (the pattern
  already exists for portable-deck transfer), surface the count, and add a bounded session undo
  mirroring the grade-undo banner.

### [P2 — OPEN] Browse ships Anki's density in vocabulary the app never explains
- **Why it matters:** `docs/PRODUCT.md` commits to explaining SRS terms when first shown and names
  Anki's dense grid as an anti-reference. Browse prints "Relearning" and a Lapses column that is
  blank on nearly every row, with no help anywhere. `GradeGuideView` proves the team can explain an
  SRS concept in-product; that pattern was not extended to phases.
- **Evidence:** `ItemBrowserView.swift:147-195, 255-263`
- **Fix:** default to Prompt / Due / State, with the rest revealable through the now-discoverable
  customization; add a state help popover mirroring `GradeGuideView`; render Lapses as "0" rather
  than "" so sighted users can tell zero from unknown, matching what VoiceOver already says.

## Persona Red Flags

- **Alex (power user):** shortcuts now have one owner each and appear in the menus that display
  them. Still open — sorting and column customization are mouse-only; browse forgets selection
  and columns on exit; Move to Deck flattens `Spanish ▸ Verbs` and `Latin ▸ Verbs` into two
  identical "Verbs" entries; a disabled Study button in browse contradicts the anti-disabled-control
  principle articulated one file over.
- **Sam (VoiceOver + keyboard):** Answer column now reachable via ⌥⌘A, and Add Item now has a menu
  home. Still open — every browse row announces its aggregate label *and* its per-cell labels, so
  one row reads five times; State and Type carry no label at all; no keyboard route to sorting. The
  accessibility layer is in places *more* informative than the visual one ("No lapses" vs. a blank
  cell) — the fix is to raise the visual, not lower the label.
- **Jamie (approachable-SRS learner):** browse mode is the intimidating screen this persona was
  defined against; the scope home's breakdown is three bare numbers under three scheduler labels
  with no `.help()`; first run gives no orientation and never mentions the `Basic` starter; the
  leech callout is Jamie's best moment and it dead-ends.

## Prior Findings — Status

| Finding | Status |
|---|---|
| Deck-first IA conflicts with the documented item-first model | **Cleared** — sidebar navigates scopes, docs and sidecar agree |
| Existing items cannot be edited | **Cleared** — item detail has an edit path |
| Grade shortcut glyphs missing on study buttons | **Cleared** |
| Hard-coded `Color.yellow` highlight | **Cleared** — uses `NSColor.findHighlightColor` |
| Accent overuse on form Save actions | **Open** — `AddItemView.swift:92`, `TemplateEditorView.swift:159`. Both new surfaces are clean |
| Duplicate template row edit affordances | **Open** — `TemplatesView.swift:316-350` |
| Schema-authoring jargon in the item-type editor | **Open, and spreading** — browse adds State and Lapses to the untranslated vocabulary |
| No first-run orientation for an empty sidebar | **Open**, deliberately deferred; partially mitigated by empty-state copy that teaches rather than reports |

## Doctor

No residual drift. `docs/DESIGN.md` and `.impeccable/design.json` agree on the type scale, the named
rules, and the component inventory; the obsolete Sidebar List Row component is gone and the scope
home and browse row are documented in its place. Zero hard-coded colors and zero
`.font(.system(size:))` in `Sources/`. Every typography call site now resolves through
`DesignSystem.Typography`.
