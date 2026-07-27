# NeoAnki2 documentation source

The user manual is published at
[neoanki2.github.io/neoanki2](https://neoanki2.github.io/neoanki2/). This
folder is both the Jekyll site source and the project reference library.

| Guide | Purpose |
| --- | --- |
| [`user/`](user/) | Complete task-oriented user guide |
| [`features.md`](features.md) | Generated feature-to-source/test coverage index |
| [`features.json`](features.json) | Machine-readable documentation ownership manifest |
| [`reference/`](reference/) | Published reference index |

| Document | Purpose |
| --- | --- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Domain model, three-layer architecture, learning-science mapping, FSRS rationale |
| [`AUTHORED_DECK_FORMAT.md`](AUTHORED_DECK_FORMAT.md) | Normative import-only JSONL deck source format |
| [`DESIGN.md`](DESIGN.md) | Visual design system — tokens, typography, layout, “The Quiet Desk” north star |
| [`LLM_DECK_AUTHORING.md`](LLM_DECK_AUTHORING.md) | Validator-driven deck authoring workflow for coding agents |
| [`PORTABLE_DECK_FORMAT.md`](PORTABLE_DECK_FORMAT.md) | Normative SQLite portable deck interchange format |
| [`PRODUCT.md`](PRODUCT.md) | Product context — users, constraints, terminology, brand (Impeccable / UX work) |

## For agents and tooling

Impeccable and similar tools resolve `PRODUCT.md` and `DESIGN.md` from this
`docs/` directory when they are not at the project root.

Visual token sidecar: [`.impeccable/design.json`](../.impeccable/design.json).

## Keeping documentation current

Run `swift Scripts/validate-docs.swift --write` after changing
`docs/features.json`, then run `./Scripts/test-fast.sh`. The validator checks
feature ownership, referenced source and test files, generated output, and local
links. Documentation screenshots are captured in reviewed CI artifacts; see
[`user/maintaining-documentation.md`](user/maintaining-documentation.md).
