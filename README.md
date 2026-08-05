# NeoAnki2

A native macOS spaced-repetition app, built ground-up in Swift 6 and SwiftUI,
with its domain logic in a standalone Swift package, `NeoAnkiCore`.

NeoAnki2 is a rewrite of the Anki idea, not a port. It deliberately drops all
legacy Anki compatibility (no HTML/CSS cards, no `.apkg`, no shared-deck import,
no SM-2) in favor of a clean, native, and scientifically grounded model.

Official macOS releases are published after every tested change to `main`.
Install or upgrade them through the official Homebrew tap:

```bash
brew install --cask neoanki2/tap/neoanki2
brew upgrade --cask neoanki2
```

Release artifacts are universal, checksummed, provenance-attested, and ad-hoc
signed. They are not yet Apple-notarized, so the first launch may require
Control-clicking NeoAnki2 in Applications and choosing **Open**.

For development on macOS 14+ with a Swift 6 Xcode toolchain, clone the
repository and run:

```bash
./Scripts/run-app.sh
```

That builds and launches a debug bundle from the checkout. Maintainers can also
install the current source revision into `/Applications` for pre-release testing:

```bash
./Scripts/install-app.sh --restart
```

See [Getting started](https://neoanki2.github.io/neoanki2/user/getting-started/)
for prerequisite checks, expected output, updates, and removal.

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

The published manual is available at
**[neoanki2.github.io/neoanki2](https://neoanki2.github.io/neoanki2/)**.
Documentation is versioned with the source in [`docs/`](docs/):

- [User guide](https://neoanki2.github.io/neoanki2/user/) — every app feature, workflow, shortcut, and limitation
- [Feature index](https://neoanki2.github.io/neoanki2/features/) — source- and test-backed coverage map
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — domain model, learning-science mapping, FSRS rationale
- [`docs/AUTHORED_DECK_FORMAT.md`](docs/AUTHORED_DECK_FORMAT.md) — import-only JSONL deck source format
- [`docs/PORTABLE_DECK_FORMAT.md`](docs/PORTABLE_DECK_FORMAT.md) — portable SQLite deck interchange format
- [`docs/DESIGN.md`](docs/DESIGN.md) — visual design system (SwiftUI shell)
- [`docs/LLM_DECK_AUTHORING.md`](docs/LLM_DECK_AUTHORING.md) — coding-agent deck authoring workflow
- [`docs/PRODUCT.md`](docs/PRODUCT.md) — product context for design and UX work
