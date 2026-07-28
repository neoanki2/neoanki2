---
command: audit
variant: native
target: Sources/NeoAnki2
slug: sources-neoanki2
platform: macOS 14+ (SwiftUI), adaptivity checks translated from iOS
generated: 2026-07-28T10-00-44Z
total_score: 16
max_score: 20
p0_count: 0
p1_count: 1
p2_count: 5
p3_count: 4
---

# Audit — Sources/NeoAnki2 (native, macOS)

First audit artifact for this project. Scored from source; `detect.mjs` does not read
Swift, so every finding below is manual static review with a file and line.

Adaptivity is translated to macOS: window resizing, `NavigationSplitView` column
behaviour, and Dynamic Type stand in for orientation, foldables, and 44pt touch
targets. Checks that genuinely cannot apply on macOS are marked N/A rather than
scored down.

## Audit Health Score

| # | Dimension | Score | Key Finding |
|---|-----------|-------|-------------|
| 1 | Accessibility | 3 | Table cells label well, but fixed-width label columns still clip at accessibility text sizes |
| 2 | Performance | 3 | `visibleItems` re-filters the whole list several times per render pass |
| 3 | Appearance & Theming | 4 | One hard-coded color left in 9,300 lines; everything else is semantic or a `DesignSystem` token |
| 4 | Platform Conformance | 4 | `NavigationSplitView`, `Table` with column customization, `.searchable`, toolbar roles, SF Symbols throughout |
| 5 | Adaptivity | 2 | Table row content is `lineLimit(2)` with no full-text path at large Dynamic Type; several sheets use fixed minimum widths |
| **Total** | | **16/20** | **Good — address Adaptivity** |

## Platform Conformance Verdict

**Pass.** This reads as a Mac app, not a ported website.

The shell is a real `NavigationSplitView` with `navigationSplitViewColumnWidth`
(`ContentView.swift:53-68`) and system column visibility rather than a hand-rolled
drawer. Browse mode is a genuine `Table` with `TableColumnCustomization`, sortable
`value:` key paths, `contextMenu(forSelectionType:)`, and `primaryAction` for
double-click (`ItemBrowserView.swift:140-219`) — the specific set of behaviours a Mac
user expects from a list of things, and the reason the Answer column can ship hidden
and still be discoverable through the standard header context menu.

Verified conformance details:

- Toolbar placements carry semantic roles: `.primaryAction` for Add Item,
  `.cancellationAction` with `.cancelAction` for Done, `.destructiveAction` for Delete
  All (`ScopeHomeView.swift:39-63`, `ItemBrowserView.swift:54-89`).
- Escape leaves browse mode via `onExitCommand` (`ItemBrowserView.swift:53`), which is
  the platform gesture rather than a custom key handler.
- Search is `.searchable(placement: .toolbar)` (`ItemBrowserView.swift:52`), so it
  lands in the toolbar search field a Mac user already knows.
- Destructive actions route through `confirmationDialog` with explicit consequence
  copy naming the cards that will be deleted (`ItemBrowserView.swift:90-114`,
  `ScopeHomeView.swift:65-80`).
- Icons are SF Symbols only; no mixed icon set anywhere in `Sources/NeoAnki2`.
- Relative dates use `Date.RelativeFormatStyle` rather than a hand-rolled formatter
  (`ScopeHomeView.swift:149`, `ItemBrowserView.swift:252`), so they localize.

## Executive Summary

- Audit Health Score: **16/20** (Good — address the weak dimension)
- Issues: **0 P0, 1 P1, 5 P2, 4 P3**
- Top issues:
  1. **[P1]** Browse table truncates at accessibility text sizes with no full-text path.
  2. **[P2]** `ItemsModel.visibleItems` re-runs the search filter on every access, several times per render.
  3. **[P2]** Relative due text is computed against `Date.now` inside cell rendering, so an open table silently goes stale.
  4. **[P2]** Fixed-width label columns in the editors clip at large Dynamic Type.
  5. **[P2]** Move to Deck presents a flat, unbounded deck list with no hierarchy.
- Next steps: `$impeccable adapt` for the Dynamic Type and table-truncation family,
  then `$impeccable optimize` for the filter and staleness findings.

## Detailed Findings by Severity

### [P1] Browse table truncates prompts with no path to the full text

- **Location**: `Sources/NeoAnki2/ItemBrowserView.swift:147-152`, `190-195`
- **Category**: Accessibility / Adaptivity
- **Impact**: `Text(item.title).lineLimit(2)` inside a `Table` cell is the correct
  default at standard text sizes, but at accessibility sizes the row cannot grow
  enough to show two lines of a poem line or a long question. The user sees a
  truncated prompt with no tooltip, no expansion, and no wrap — the only recovery is
  opening the item. For a library whose whole purpose is recognizing which item is
  which, a truncated prompt is a failed lookup.
- **Guideline**: HIG *Typography* — support Dynamic Type; content must remain legible,
  not merely non-overlapping.
- **Recommendation**: Add `.help(item.title)` so hover reveals the full prompt, and
  drop to `lineLimit(1)` with a wider default Prompt column at accessibility sizes via
  `@Environment(\.dynamicTypeSize)`. The VoiceOver path is already correct
  (`accessibilityLabel(for:)` at line 265 reads the full title plus state), so this is
  a low-vision-with-sight problem specifically.
- **Suggested command**: `$impeccable adapt`

### [P2] `visibleItems` re-filters the entire list on every access

- **Location**: `Sources/NeoAnki2/ItemsModel.swift:39-41`; consumed at
  `ItemBrowserView.swift:40`, `118-119`, `197`
- **Category**: Performance
- **Impact**: `visibleItems` is a computed property that calls
  `ItemBrowsing.filter(items, search:)` every time it is read. One render pass reads it
  at least three times — the empty-search-results check, the `subtitle` count, and the
  table's `rows` builder — so a 5,000-item library performs three full string scans per
  keystroke while typing in the search field.
- **Recommendation**: Cache the filtered array and recompute it in a `didSet` on
  `searchText` and at the end of `load`, the way `tableSort` already recomputes `items`
  on assignment (`ItemsModel.swift:27-31`). The pattern is already in this file; the
  filter just does not follow it.
- **Suggested command**: `$impeccable optimize`

### [P2] Due column is computed against `Date.now` at render time and never refreshes

- **Location**: `Sources/NeoAnki2/ItemBrowserView.swift:249-253`, and
  `item.schedule?.isDue()` at line 157
- **Category**: Performance / Correctness of displayed state
- **Impact**: `dueText` reads `.now` while building a cell. Nothing invalidates the
  view when wall-clock time crosses a card's due moment, so a table left open reports
  "in 2 min" indefinitely, and the primary/secondary emphasis on the Due column drifts
  out of sync with the scope home's headline, which *is* snapshotted through
  `scopeSummary`.
- **Recommendation**: Pass the same `asOf` instant the model loaded with into the view,
  so the table's notion of "now" matches the sidebar's and the headline's, and refresh
  it on the existing reload path rather than implicitly per frame.
- **Suggested command**: `$impeccable optimize`

### [P2] Fixed-width label columns clip at large Dynamic Type

- **Location**: `Sources/NeoAnki2/GradeGuideView.swift:21` (`width: 52`),
  `GradeGuideView.swift:34` (`width: 360`), `ClozeFieldEditor.swift:86` (`width: 70`),
  `ItemTypeEditorView.swift:61` (`width: 130`)
- **Category**: Accessibility / Adaptivity
- **Impact**: These are text-bearing containers with hard widths. At accessibility
  sizes the label inside grows but the frame does not, so shortcut glyphs and field
  labels truncate. This is the same unresolved XXL overflow family the prior critiques
  recorded, now enumerated with locations.
- **Recommendation**: Replace fixed widths with `ViewThatFits` or a `Grid` that lets the
  measure grow, following `ScopeHomeView.swift:159-170`, where the card-state row
  already falls back from a horizontal to a vertical arrangement.
- **Suggested command**: `$impeccable adapt`

### [P2] Move to Deck is a flat, unbounded list

- **Location**: `Sources/NeoAnki2/ItemBrowserView.swift:221-237`
- **Category**: Conformance / Cognitive load
- **Impact**: The menu iterates `decksModel.summaries` in storage order with no
  indentation or path, even though decks nest (`parentID` exists and the sidebar draws
  a tree). Two subdecks named "Sonnets" under different parents are indistinguishable
  here, and a library with thirty decks produces a thirty-item flat menu — well past the
  four-option working-memory threshold.
- **Recommendation**: Render the deck tree with nested `Menu`s or a path-qualified
  title, reusing the sidebar's existing `DeckTree`.
- **Suggested command**: `$impeccable clarify`

### [P2] Search has no scope affordance and clears silently on exit

- **Location**: `Sources/NeoAnki2/ItemBrowserView.swift:52`,
  `ContentView.swift:357-360`
- **Category**: Conformance
- **Impact**: The search field is only present in browse mode, and `closeBrowse` resets
  `searchText` without telling the user. Re-entering browse shows the full list again,
  which is defensible, but a user who leaves to open an item and comes back has lost
  their query with no indication that it existed.
- **Recommendation**: Either preserve the query across a browse round-trip or make the
  reset visible by returning to browse with the search field focused and empty.
- **Suggested command**: `$impeccable clarify`

### [P3] `⌥⌘B`, `⌘⇧S`, and `⌘N` are each bound in two places

- **Location**: `LibraryCommands.swift:65` and `ScopeHomeView.swift:44` (`⌥⌘B`);
  `StudyCommands.swift:56`, `ScopeHomeView.swift:123`, `ItemBrowserView.swift:71`
  (`⌘⇧S`); `ScopeHomeView.swift:53` and `ItemBrowserView.swift:79` (`⌘N`)
- **Category**: Conformance
- **Impact**: Each shortcut exists on both a menu command and a toolbar button. The
  duplicates resolve correctly today because the surfaces are mutually exclusive
  branches of `ContentView.detail`, and the toolbar copy is what draws the shortcut
  hint in the button's tooltip. Recording it because the pattern will bite when two
  surfaces are ever visible at once.
- **Recommendation**: Leave as-is; if a third surface is added, move ownership to the
  menu and let toolbar buttons inherit the hint.
- **Suggested command**: none (documentation only)

### [P3] VoiceOver reads the browse row's state twice

- **Location**: `Sources/NeoAnki2/ItemBrowserView.swift:150`, `158`, `172`, `186`
- **Category**: Accessibility
- **Impact**: The Prompt cell's `accessibilityLabel` already summarizes phase, due
  date, card count, and type, and the Due, Lapses, and Cards cells then carry their own
  labels. Traversing a row cell-by-cell hears each fact twice.
- **Recommendation**: Keep the per-cell labels, which are what column navigation needs,
  and reduce the Prompt cell's label to the title plus due state only.
- **Suggested command**: `$impeccable polish`

### [P3] One hard-coded color remains

- **Location**: `Sources/NeoAnki2/StudyView.swift:333`
  (`.foregroundStyle(.green)` on the "Your response matches" label)
- **Category**: Theming
- **Impact**: Minimal in practice — `.green` is a system color that adapts to
  appearance, and the label pairs it with `checkmark.circle.fill`, so meaning is never
  carried by color alone. It is still the one place in the app that names a hue instead
  of a role.
- **Recommendation**: Route it through a `DesignSystem` semantic token if correctness
  feedback ever needs its own color; otherwise leave it.
- **Suggested command**: `$impeccable colorize`

### [P3] Study progress toolbar has no live region

- **Location**: `Sources/NeoAnki2/StudyView.swift:188-192`
- **Category**: Accessibility
- **Impact**: `headerLabel` changes as cards are graded, and the label is well written
  ("Progress, ..."), but nothing announces the change; a VoiceOver user must navigate
  back to the header to learn where they are in the session.
- **Recommendation**: The app already has `AccessibilityNotifier`
  (`DesignSystem.swift:107`, `AccessibilityRouting.swift`) for the error banner. Reuse
  it for session progress at session start and completion, not per card.
- **Suggested command**: `$impeccable polish`

## Patterns & Systemic Issues

- **Fixed dimensions are the one recurring drift.** Twenty-three `.frame` calls with
  numeric literals, of which four carry text at a hard width. Sheet minimums
  (`AddItemView.swift:98`, `ImportView.swift:111`, `TemplateEditorView.swift:165`,
  `DeckBuilderSheet.swift:75`) are legitimate on macOS — a window needs a floor — but
  the text-bearing ones are not.
- **Snapshot discipline is now real but not yet total.** `ScopeSummary` gives the app
  one due-count truth per reload, and every reload path threads a single `asOf`
  (`ContentView.swift:564-568`, `ItemsModel.swift:58`, `ItemBrowserView.swift:239-245`).
  The exception is per-row relative date text, which still reads the clock directly.
- **Semantic color and typography are effectively complete.** Zero
  `.font(.system(size:))` in production views, and one named hue in 9,317 lines.

## Positive Findings

- **Every interactive element in the two new surfaces carries an identifier, and every
  non-obvious one carries a label.** 18 accessibility annotations in `ScopeHomeView`
  and 16 in `ItemBrowserView`, including derived labels for cells whose visual text is
  an em-dash placeholder (`ItemBrowserView.swift:270-276`) — a blank cell that reads as
  "Not scheduled" rather than nothing.
- **Reduce Motion is honored on every animated path.** All three
  `columnVisibility` transitions branch on `reduceMotion`
  (`ContentView.swift:601-638`), and the answer reveal routes through
  `StudyAnimation.revealAnswer` (`DesignSystem.swift:117-127`), which takes the flag as
  a parameter so it cannot be forgotten at a call site.
- **The empty states teach instead of reporting.** "Nothing to Remember Yet" explains
  what the app will do with what you add (`ScopeHomeView.swift:241-250`), and the
  nothing-due state names the time the next card returns rather than showing a dead
  disabled button (`ScopeHomeView.swift:143-151`).
- **`ViewThatFits` in the card-state row** (`ScopeHomeView.swift:159-170`) is the
  correct macOS translation of adaptivity: the breakdown reflows from a row to a column
  when the split view narrows or text grows, with no breakpoint hard-coded.
- **A previously flagged hard-coded `Color.yellow` highlight is gone.**
  `DesignSystem.contentHighlightBackground` now uses `NSColor.findHighlightColor`
  (`DesignSystem.swift:20`), so rich-text highlight follows appearance and Increased
  Contrast.

## Closed Immediately After This Audit

Three findings were repaired in the same working session, because the surface brief
required a Dynamic Type path for the new table and the fix was small. Recorded here so
this artifact does not misreport the current tree.

- **[P1] Table truncation** — the Prompt and Answer cells now take a third line and a
  wider measure at accessibility sizes, and carry `.help(...)` so hover reveals the
  full text (`ItemBrowserView.swift:150-152`, `195-197`, `291-303`).
- **[P2] `visibleItems` re-filtering** — now a stored property invalidated from
  `items` and `searchText` (`ItemsModel.swift:12-14`, `35-48`), covered by
  `browseSearchResultsTrackItemChanges` in `Tests/NeoAnki2Tests/ScopeHomeAndBrowseTests.swift`.
- **[P3] Doubled VoiceOver row summary** — the Prompt cell's label stops at title,
  state, and due (`ItemBrowserView.swift:283-287`).

The critique's evidence scan, run in parallel, turned up four more small ones that were
also repaired in place:

- **Unlabeled browse controls** — the three context-menu buttons, the per-deck Move to
  Deck buttons, and the browse loading state now carry identifiers, matching their
  toolbar equivalents (`ItemBrowserView.swift:38`, `:204-217`, `:227`).
- **Two empty states sharing one symbol** — the deck-empty state now uses
  `folder.badge.plus` against the library-empty `rectangle.stack.badge.plus`, which is
  what the empty-state iconography rule in `DESIGN.md` requires
  (`ScopeHomeView.swift:264`, `ItemBrowserView.swift:311`).
- **An em-dash State cell read as silence** — now "No cards yet"
  (`ItemBrowserView.swift:289-291`).
- **Typography bypasses** — the sidebar row's `.headline`/`.caption` ramp is now the
  `uiRowTitle`/`uiRowMeta` tokens, recorded in `DESIGN.md` and the sidecar, and
  `ImportView`'s two `.font(.callout)` calls route through `uiSecondary`. No visual
  change; the sidecar's Sidebar Scope Row component is now truthful.

The design review, which finished after these, found two more places where this work did
not meet its own brief. Both were closed here rather than filed:

- **[P1] The due headline was not the focal element** — 17pt semibold against a 15pt
  semibold section label two blocks down, with the Study button carrying the hierarchy
  the type should have. Now a `uiDisplay` token (bold, not larger, since card sizes stay
  reserved), a demoted "Cards" group label, no scope caption competing above it, and an
  uneven vertical rhythm (`ScopeHomeView.swift:88-95`, `:106-110`, `:157-160`,
  `DesignSystem.swift:53-58`).
- **[P1] The Answer column's reveal was undiscoverable** — the header context menu was
  the only path, unreachable by keyboard, and forgotten on every exit. Now
  `Library ▸ Show / Hide Answer Column` at ⌥⌘A, persisted in `@AppStorage`, with
  header-menu changes writing back to the same preference
  (`LibraryCommands.swift:47-56`, `ItemBrowserView.swift:16-30`, `:60-66`,
  `ContentView.swift:34-36`).

- **[P3] Three shortcuts with two owners each** — ⌥⌘B, ⌘⇧S, and ⌘N are now declared
  only on their menu commands, which is where macOS draws them; the toolbar buttons keep
  their actions and lose their bindings (`ScopeHomeView.swift:40-54`, `:118-122`,
  `ItemBrowserView.swift:76-90`). ⌘N gained the menu owner it never had:
  `File ▸ New Item` (`LibraryCommands.swift:39-49`).

Still open, and reflected in the score above: the Due column's per-render `.now` read,
the four fixed-width text frames, the flat Move to Deck menu, the silent search reset,
and study progress announcements. `MediaFieldEditor.swift:60`'s `.font(.title2)` is
left alone deliberately — it sizes a drop-zone symbol, not text, so the Card Type Scale
Rule does not reach it.

## Recommended Actions

1. **[P1] `$impeccable adapt`**: Dynamic Type across the browse table and the four
   fixed-width text frames — table row truncation first, since it defeats the surface's
   only job.
2. **[P2] `$impeccable optimize`**: Cache the browse search filter, and pass a
   snapshotted `asOf` into the Due column instead of reading `.now` per cell.
3. **[P2] `$impeccable clarify`**: Deck hierarchy in the Move to Deck menu, and make
   the search reset on leaving browse visible rather than silent.
4. **[P3] `$impeccable polish`**: Trim the doubled VoiceOver row summary and announce
   session progress at start and completion.
