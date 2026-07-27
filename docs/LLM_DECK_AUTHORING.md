---
title: Authoring decks with coding agents
description: Generate reviewable .neoanki source bundles with deterministic records, validation, and safe media references.
parent: Reference
---

# Authoring NeoAnki decks with coding agents

## Why the format is JSON Lines

This workflow targets current filesystem-capable coding agents such as Codex,
Claude Code, and Cursor, not a chat response copied by hand.

Frontier agents are strong at:

- inspecting repository documentation and examples;
- editing several files over a long-running task;
- producing familiar programming and data formats;
- invoking deterministic tools; and
- repairing localized compiler or validator diagnostics.

Their remaining weaknesses matter more than old prompt recipes:

- schema-valid output can still contain semantically wrong references;
- long generated artifacts are vulnerable to truncation and duplicated content;
- context quality degrades when instructions and repeated structure become
  excessive; and
- agents can confidently invent identifiers or assume files exist.

The format therefore uses familiar JSON rather than a novel language, one
record per line rather than a monolithic document, explicit bounded item
shards rather than implicit discovery, and a semantic validator rather than
prompt-only compliance.

This follows current official guidance to keep durable instructions concise
and back them with executable checks:

- [OpenAI Codex best practices](https://developers.openai.com/codex/learn/best-practices)
- [Claude Code best practices](https://code.claude.com/docs/en/best-practices.md)

It also reflects current structured-generation findings: constrained syntax
substantially improves shape but does not eliminate structural-reference or
semantic failures, and hard constraints can steer generation onto worse
semantic paths:

- [Empirical Study for Structured Output Control in LLMs for Software Engineering](https://arxiv.org/html/2606.09395)
- [The Hidden Cost of Structured Generation in LLMs](https://arxiv.org/html/2603.03305)

## Recommended agent workflow

Give the agent a content goal and point it to:

1. [`AUTHORED_DECK_FORMAT.md`](AUTHORED_DECK_FORMAT.md)
2. the [Biology authored-deck example]({{ site.baseurl }}/examples/)
3. the validator command below

Ask it to complete this loop:

```text
1. Create or update the .neoanki bundle.
2. Keep deck/type declarations in deck.jsonl.
3. Split items into coherent, bounded items/*.jsonl files.
4. Run the validator.
5. Fix every diagnostic and rerun until validation succeeds.
6. Summarize item, type, deck, and media counts.
```

Validation:

```bash
swift run --package-path NeoAnkiCore neoanki-deck validate path/to/Deck.neoanki
```

Do not ask the model to generate UUIDs, SHA-256 digests, cloze offsets,
timestamps, cards, or scheduling state. The importer owns those.

## Task template

This is context, not a fragile “magic prompt”:

```text
Create <path>.neoanki as a NeoAnki Authored Deck Format v1 bundle.
Read docs/AUTHORED_DECK_FORMAT.md and use docs/examples/Biology.neoanki as the
structural example. Cover <learning goals>. Prefer atomic retrieval prompts,
clear answers, and tags useful for filtering. Split item records into files of
roughly 100–500 related items. Use only media files that actually exist under
the bundle's media/ directory. Run:

swift run --package-path NeoAnkiCore neoanki-deck validate <path>.neoanki

Fix all diagnostics before finishing. Do not import the deck or modify a
NeoAnki library.
```

The content brief should specify audience, prior knowledge, language, desired
coverage, and any prohibited material. Those decisions affect learning quality
and cannot be inferred from serialization.

## Chunking large decks

- Define each type once in `deck.jsonl`.
- Use stable semantic identifiers such as `basic`, `listening`, and
  `cell_biology`; do not encode ordinal position in identifiers unless order is
  meaningful.
- Keep each item on one physical line.
- Split by topic before a shard becomes difficult to inspect. Around 100–500
  items per file is a useful working range, not a format limit.
- Add every shard explicitly to the manifest `parts` array.
- Validate after each shard, not only at the end.
- Avoid generating several shards concurrently if they would duplicate the
  same learning objectives.

A truncated generation normally damages only its final JSONL record. Delete or
repair that record; do not regenerate already validated shards.

## Content guidance

- Use one item for one coherent fact or skill.
- Use multiple templates when the same knowledge genuinely benefits from
  different retrieval routes.
- Mark optional templates with `generateWhen` when their media or field may be
  absent.
- Use cloze markers instead of calculating offsets.
- Use native rich spans only when styling carries meaning.
- Never insert HTML or Markdown expecting it to render as markup.
- Verify factual correctness separately from format validation. A valid deck
  can still teach false or low-quality material.

## Diagnostic repair

Diagnostics have a stable code, source file, and line. Repair the referenced
record rather than rewriting the bundle.

Common categories:

- `AD01x`: source I/O or malformed JSON;
- `AD02x`: member shape or primitive type;
- `AD10x`: manifest and source-part declarations;
- `AD12x`: type/template structure;
- `AD20x`: cross-record semantic validation;
- `AD22x`: item/reference validation;
- `AD24x`–`AD26x`: content, media, and cloze validation; and
- `AD30x`: destination type-resolution failure.

Validation does not mutate a library. Import remains a deliberate action in
NeoAnki.

## Why not YAML or a custom DSL

YAML offers pleasant block strings, but introduces indentation and implicit
typing failures, a native parser dependency, and a larger untrusted-input
surface. A safe profile would still need to disable aliases, tags, merge keys,
directives, and graph features.

A custom DSL could eventually improve terseness and multiline ergonomics, but
would require a permanent parser, formatter, fuzz corpus, compatibility policy,
and editor tooling. It should be considered only if real JSONL authoring data
shows a material token or repair-cost disadvantage.

JSONL is intentionally conservative: current agents already know it, existing
tools inspect it, and NeoAnki can focus its complexity on semantic validation
and safe import.
