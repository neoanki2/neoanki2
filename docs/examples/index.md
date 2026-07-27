---
title: Example authored deck
description: Explore a valid Biology .neoanki bundle with a manifest and split JSON Lines item sources.
parent: Reference
---

# Biology authored deck example

This valid `.neoanki` source bundle demonstrates a deck manifest and JSONL item
part. The fast test suite validates it with the same Swift validator used by the
CLI.

- [`deck.jsonl`](Biology.neoanki/deck.jsonl)
- [`items/cells.jsonl`](Biology.neoanki/items/cells.jsonl)

Download the files while preserving the `Biology.neoanki/items/` directory
structure, then run:

```bash
swift run --package-path NeoAnkiCore neoanki-deck validate docs/examples/Biology.neoanki
```
