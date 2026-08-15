# NeoAnki2 documentation source

The user manual is published at
[neoanki2.github.io/user](https://neoanki2.github.io/user/). This
folder is both the Jekyll site source and the project reference library.

| Guide | Purpose |
| --- | --- |
| [`user/`](user/) | Complete task-oriented user guide |
| [`user/developer/`](user/developer/) | Canonical contributor and maintainer guide |
| [`api/`](api/) | Generated HTTP operations, schemas, errors, and OpenAPI JSON |
| [`features.md`](features.md) | Generated feature-to-source/test coverage index |
| [`features.json`](features.json) | Machine-readable documentation ownership manifest |
| [`reference/`](reference/) | Published reference index |

| Document | Purpose |
| --- | --- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Domain model, three-layer architecture, learning-science mapping, FSRS rationale |
| [`AUTHORED_DECK_FORMAT.md`](AUTHORED_DECK_FORMAT.md) | Normative import-only JSONL deck source format |
| [`DESIGN.md`](DESIGN.md) | Visual design system — tokens, typography, layout, “The Quiet Desk” north star |
| [`LLM_DECK_AUTHORING.md`](LLM_DECK_AUTHORING.md) | Validator-driven deck authoring workflow for coding agents |
| [`LOCAL_API.md`](LOCAL_API.md) | Normative local automation API requirements and version-1 acceptance criteria |
| [`api/index.md`](api/index.md) | Generated public HTTP API reference; never edit by hand |
| [`VOCABULARY_API.md`](VOCABULARY_API.md) | Normative vocabulary-operation design requirements |
| [`user/local-api.md`](user/local-api.md) | Enable, authorize, troubleshoot, and report security issues for the local API |
| [`PORTABLE_DECK_FORMAT.md`](PORTABLE_DECK_FORMAT.md) | Normative SQLite portable deck interchange format |
| [`OFFLINE_VOCABULARY.md`](OFFLINE_VOCABULARY.md) | Local dataset normalization, `.neovocab` compilation, validation, and search |
| [`PRODUCT.md`](PRODUCT.md) | Product context — users, constraints, terminology, brand (Impeccable / UX work) |
| [`ADDONS.md`](ADDONS.md) | Deck-builder extension boundaries and contribution workflow |
| [`RELEASING.md`](RELEASING.md) | macOS release preparation, promotion, and installation |
| [`IOS_RELEASE.md`](IOS_RELEASE.md) | iOS/iPadOS build, signing, and distribution gates |

## For agents and tooling

Impeccable and similar tools resolve `PRODUCT.md` and `DESIGN.md` from this
`docs/` directory when they are not at the project root.

Visual token sidecar: [`.impeccable/design.json`](../.impeccable/design.json).

## Keeping documentation current

Run `swift Scripts/validate-docs.swift --write` after changing
`docs/features.json`. API contract changes also require
`swift run neoanki-api-reference generate`. Then run `./Scripts/test-fast.sh`.
The validators check
feature ownership, referenced source and test files, generated output, local
links, the generated API reference, required screenshot coverage, and screenshot freshness. Documentation
screenshots are captured in reviewed CI artifacts; see
[`user/developer/documentation.md`](user/developer/documentation.md).
