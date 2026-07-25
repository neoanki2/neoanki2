# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

macOS is the primary shipping target today (Swift 6 / SwiftUI). iOS and iPadOS
are planned later, sharing `NeoAnkiCore`. UI work should follow Apple HIG per
platform; Mac conventions (split navigation, menus, keyboard study flow) take
priority until a mobile shell exists.

## Users

**Primary:** The builder as a general learner — someone who wants spaced
repetition to feel approachable, not intimidating. Clarity, calm layout, and
plain language matter more than power-user density or feature sprawl.

**Secondary (future):** SRS-literate learners who outgrow Anki's legacy model
and want a native alternative; they will tolerate more density once core flows
are obvious.

**Situation:** Solo study at a desk on Mac — short daily review sessions,
occasionally adding new items. Success means finishing due cards without
confusion and trusting that scheduling "just works."

## Product Purpose

NeoAnki2 helps you remember what you choose to learn by turning structured
knowledge into atomic retrieval practice, scheduled with modern memory science.

**Success looks like:**

- Due cards are reviewed in a clear, low-friction loop (prompt → respond → grade).
- Adding items is understandable without reading architecture docs.
- Scheduling adapts via FSRS without manual ease tuning.
- The app feels like a native Mac tool, not a prototype web view.

## Positioning

A ground-up native spaced-repetition app where **content is SwiftUI data, not
documents** — no HTML/CSS cards, no template markup, no sanitization layer.
Knowledge is domain-neutral (`ItemType`, `FieldDef`, `Template`); anatomy,
music, and chemistry are user-declared schemas, not baked-in types. FSRS sits
behind a swappable `Scheduler` protocol. A neighboring product cannot truthfully
claim all three without abandoning its legacy model.

On first run the app offers a neutral `Basic` starter so adding an item requires
no setup. It is ordinary user-owned schema data: it can be deleted, its one-time
seed is persisted, and later launches do not recreate it. `NeoAnkiCore` clients
can choose an empty starter set.

## Operating Context

- **Environment:** macOS desktop, single-user, local SQLite store
  (`AppDatabase.defaultURL`).
- **Core workflows today:**
  1. Browse items in the main window
  2. Add an item via form (fields from a selected item type)
  3. Study due cards in the main detail pane (reveal → Again/Hard/Good/Easy)
  4. Manage item types/templates and import JSON or CSV from the native shell
- **Architecture split:** `NeoAnkiCore` (domain, scheduling, persistence);
  `NeoAnki2` (SwiftUI shell). See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the three-layer model.
- **Dev verification:** `./Scripts/test-fast.sh` for unit/flow tests; UI tests
  are CI/manual unless explicitly requested.

## Capabilities and Constraints

### Confirmed (user + repository)

| Area | Status |
| --- | --- |
| Native `ContentValue` rendering | Required — no HTML/CSS templates |
| Domain-neutral schema | Required — no subject in core types |
| FSRS scheduling | Required — no SM-2 / ease hell |
| Keyboard study flow on Mac | Required — grade and navigate without mouse-only dependency |
| Minimal system-native UI | Required — semantic SwiftUI, no heavy custom chrome |
| macOS first | Current focus; shared core for future iOS/iPad |
| Item list + add + study session | Implemented (early) |
| Text/rich/number content display | Implemented |
| Media display (audio/image/gif/video) | Implemented — sandbox `MediaStore`, study + preview |
| Cloze display + authoring | Implemented — `FieldType.cloze`, structured blanks (no markup) |
| Deck organization UI | Implemented |
| Multiple item types / template authoring UI | Implemented |
| Native JSON/CSV import (core) | Implemented — text fields; media paths + cloze objects in JSON |
| Import UI | Implemented — File menu/import sheet with JSON and CSV file selection |
| Anki import (`.apkg`, shared decks) | **Non-goal** per [`ARCHITECTURE.md`](ARCHITECTURE.md) — clean schema over migration |

### Terminology (product-facing)

| Term | Meaning |
| --- | --- |
| Item | One record of knowledge (field values for an item type) |
| Item type | User-declared schema: fields + templates |
| Card | One retrieval probe generated from an item × template |
| Study session | Reviewing due cards sequentially |
| Again / Hard / Good / Easy | FSRS review grades (1–4) |

### Open decisions

- iOS/iPad interaction model (touch targets, navigation) — deferred until Mac shell is coherent

## Brand Commitments

- **Name:** NeoAnki2
- **Voice:** Calm, direct, learner-facing — explain SRS terms when first shown; avoid jargon in errors
- **Visual stance:** System-native minimalism; SF Symbols; semantic colors and Dynamic Type
- **Explicit non-goals:** No gamification, no hype, no "productivity theater"

## Evidence on Hand

| Asset | Location |
| --- | --- |
| Architecture & philosophy | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| Visual design system | [`DESIGN.md`](DESIGN.md) |
| Product context | [`PRODUCT.md`](PRODUCT.md) |
| Documentation index | [`README.md`](README.md) |
| Project overview | [`../README.md`](../README.md) |
| Runnable macOS app | `Sources/NeoAnki2/` |
| Domain package | `NeoAnkiCore/` |

**Do not fabricate:** testimonials, user counts, benchmark claims, pricing,
shared-deck catalogs, or Anki compatibility promises.

## Product Principles

1. **Clarity over cleverness** — if a learner must read docs to use a screen, the screen failed.
2. **Native data, native UI** — content and presentation stay in Swift/SwiftUI; no document pipeline.
3. **Domain stays out of the core** — new subjects are data, not code changes.
4. **Scheduling is invisible until it isn't** — FSRS runs quietly; surface stats only when they help trust.
5. **Mac-first craft** — menus, keyboard, and window structure should match platform expectations before mobile adaptation.

## Accessibility & Inclusion

- VoiceOver labels on all interactive controls (not just test identifiers)
- Dynamic Type and Increased Contrast supported via semantic system styles
- Keyboard-only path through add-item and study flows
- Plain-language error messages; never color alone for state
- Reduce Motion honored for custom transitions and media autoplay
