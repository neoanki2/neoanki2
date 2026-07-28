---
version: 1
slug: "sources-neoanki2-scopehomeview-swift"
primary_target: "Sources/NeoAnki2/ScopeHomeView.swift"
related_targets: ["Sources/NeoAnki2/ItemBrowserView.swift"]
---

# Surface brief: Scope Home and Item Browser

Visitor mode: **Operate**. The user is in a task. Scanability, native Mac
expectations, and earned familiarity outrank expression. Brand lives in precise
details, not in novelty.

Interview substitution: the discovery round was answered by a confirmed
implementation plan rather than a live question round, at the user's explicit
instruction to proceed. Direction, scope, and constraints below are taken from
that confirmation, not inferred.

## 1. Job and audience

A solo learner at a Mac desk opens NeoAnki2 for a short daily review. They arrive
wanting one thing answered: *is there anything to study right now, and can I
start?* A distinct, much rarer visit is corrective: find one item to fix a typo,
check whether something was already added, move items into a deck, or work out
which cards keep failing.

Today one screen tries to serve both and serves neither: a full-width
enumeration of items that prints answers, carries no scheduling state, cannot be
searched or sorted, and lists sequential content in reverse.

## 2. Outcome and proof

- **Scope home:** the due count and a live Study button are the first things
  read. When nothing is due, the next due time replaces a dead disabled control.
- **Item browser:** finding a known item takes a search, not a scroll; triage
  reads state (due, phase, lapses) rather than content.
- Product-specific truth: cards carry independent FSRS memory per item-template
  pair, so state is per-card and aggregates to the item. No competitor shell
  reports "8 due in this scope, next in 3 hours" off the same model.

## 3. Selected direction

Visual authority is the incumbent world in `docs/DESIGN.md` — The Quiet Desk,
preserved, not replaced. Structural thesis: **split the two jobs across two
surfaces instead of overloading one list.** The detail pane defaults to a calm
summary; enumeration becomes a deliberate mode.

Focal moment: the due count paired with Study, sitting in the reading measure
with generous space around it. Nothing else on the scope home competes.

Implementation consequence: `ScopeHomeView` replaces `DeckDetailView` as the
default detail branch; `DeckDetailView` becomes `ItemBrowserView` built on
`Table`.

## 4. Scope and boundaries

In scope: scope home, item browser, their entry points, and the store queries
that feed them.

Untouched: `Item`, `Card`, `CardGenerator`, card reconciliation, FSRS, the study
loop, the deck sidebar, and all schema-authoring surfaces.

Anti-goals: no dashboard, no charts, no streaks, no rings, no stats during
review, no reverting the sidebar to item-first, and no answers visible in the
library by default.

## 5. States and ranges

Realistic scope sizes: 0 items (first run), 11 items (one poem deck), a few
hundred (typical), several thousand (upper bound the browser must survive).

Material states per surface:

- Scope home: loading, empty scope, nothing due (with next due time), cards due,
  leeches present, load error.
- Browser: loading, empty scope, empty search result, single selection, multi
  selection, load error.

Data range notes: due counts reach three digits; `nextDueAt` may be minutes or
months away; lapses are usually 0 and occasionally large.

## 6. Interaction and layout

Scope home, top to bottom: scope name, due headline with Study, neutral
new/learning/review breakdown, leech callout when present, secondary Browse
link. Prose stays inside the 600pt reading measure.

Browser: full detail width (the reading measure governs card text, not tables).
Sortable column headers, search field, Answer column hidden by default and
user-revealable, multi-select for Move to Deck and Delete. Row selection opens
item detail. Escape returns to the scope home.

Feedback and transitions: state changes only, 150-250ms, Reduce Motion honored.
Skeleton or inline progress rather than a spinner parked mid-content.

## 7. Constraints and open decisions

Binding, not to be reinvented by the builder:

- Card Type Scale Rule: chrome never borrows card sizes. The due headline uses
  `Typography.uiTitle`, never `.largeTitle` or `.title`.
- One Accent Rule: Study is the only accented control on these surfaces. The
  browser gets no prominent accent button.
- No Gamification Palette Rule: the breakdown is typographic and neutral. No
  colored pills, rings, or bars.
- "No scheduling statistics during active review" is scoped to active review; a
  pre-session home is the sanctioned place for these numbers, and DESIGN.md must
  say so.
- Semantic colors and Dynamic Type throughout; VoiceOver labels and traits on
  every column and control; no fixed-width text container without a large-size
  path.

Deferred, deliberately: first-run activation and orientation (an `onboard` job),
suspend/unsuspend UI, and schema-authoring vocabulary.
