---
title: Authored deck JSON Schemas
description: Download the JSON Schemas for .neoanki manifests, item types, decks, and items.
audience: reference
parent: Reference
---

# Authored deck JSON Schemas

These schemas describe the JSON records used by `.neoanki` authored decks.
NeoAnki2's Swift validator remains authoritative and applies additional
cross-record checks.

- [Manifest schema](authored-manifest.schema.json)
- [Deck metadata schema](authored-deck.schema.json)
- [Item type schema](authored-type.schema.json)
- [Item schema](authored-item.schema.json)

Validate a complete bundle with [`neoanki-deck validate`](../user/cli/).
