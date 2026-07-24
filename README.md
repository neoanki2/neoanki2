# NeoAnki2

A native macOS spaced-repetition app, built ground-up in Swift 6 and SwiftUI,
with its domain logic in a standalone Swift package, `NeoAnkiCore`.

NeoAnki2 is a rewrite of the Anki idea, not a port. It deliberately drops all
legacy Anki compatibility (no HTML/CSS cards, no `.apkg`, no shared-deck import,
no SM-2) in favor of a clean, native, and scientifically grounded model.

## Principles

- **Native-only.** Card content is data (`ContentValue`), rendered by SwiftUI.
  No HTML, no CSS, no template markup.
- **Domain-neutral.** The core knows about no subject. Anatomy, music,
  chemistry, and geography are all just user-declared item types. You can delete
  any subject without touching a single type.
- **Learning-science first.** The schema encodes the testing effect, encoding
  specificity, desirable difficulties, dual coding, atomicity, and interleaving.
- **Modern scheduling.** FSRS (Difficulty–Stability–Retrievability) is the
  scheduler, behind a swappable `Scheduler` protocol. No SM-2, no ease hell.

## Layout

```
NeoAnkiCore/Sources/NeoAnkiCore/
  Content/   ContentValue, MediaRef        — the raw knowledge, native values
  Schema/    ItemType, FieldDef,           — how content is structured,
             Template, Skill                  presented, and tested
  Models/    Item, Card, Deck,             — concrete instances and generation
             CardGenerator
  SRS/       MemoryState, Scheduler,       — memory and scheduling (FSRS)
             ReviewRating, ReviewLog
```

## Documentation

All project docs live in [`docs/`](docs/) — see [`docs/README.md`](docs/README.md) for the index:

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — domain model, learning-science mapping, FSRS rationale
- [`docs/DESIGN.md`](docs/DESIGN.md) — visual design system (SwiftUI shell)
- [`docs/PRODUCT.md`](docs/PRODUCT.md) — product context for design and UX work
