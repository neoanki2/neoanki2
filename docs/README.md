# NeoAnki2 documentation

Project docs live here. The repo root [`README.md`](../README.md) is the quick
start; this folder is the reference library.

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
