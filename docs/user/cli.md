---
title: Deck authoring CLI
nav_order: 11
parent: User Guide
---

# Deck authoring CLI

`neoanki-deck` is a command-line tool in the `NeoAnkiCore` Swift package. Its
user-facing command validates editable `.neoanki` authored deck bundles before
you import them in the app.

## Validate a bundle

From the repository root, run:

```bash
swift run --package-path NeoAnkiCore neoanki-deck validate path/to/Biology.neoanki
```

The path must identify a directory bundle whose name ends in `.neoanki`.
Validation checks the complete bundle without importing it, including:

- `deck.jsonl`, listed item parts, UTF-8 JSONL syntax, and exact allowed keys;
- identifiers, references, deck hierarchy, item types, fields, templates, and
  generation conditions;
- item values, tags, required fields, rich text, and cloze markers;
- media paths, confinement, signatures, kinds, sizes, and aggregate limits; and
- source-file, record, part, deck, type, field, template, item, and media
  limits.

A valid bundle prints:

```text
Valid authored deck: /absolute/path/to/Biology.neoanki
```

and exits with status `0`. An invalid bundle writes one or more stable,
compiler-style diagnostics to standard error and exits nonzero:

```text
/path/Biology.neoanki/items/cells.jsonl:18: AD222: Item contains unknown field "backs".
```

Each diagnostic includes the source file, line, stable `AD…` code, and
description. Fix every diagnostic, rerun validation, and import only after the
command succeeds. Validation does not modify the bundle or your NeoAnki2
library.

If the invocation itself is wrong, the tool prints:

```text
Usage: neoanki-deck validate <path.neoanki>
```

## What validation does not do

The command validates authored `.neoanki` source only. It does not:

- validate, create, import, or export `.neodeck` SQLite files;
- import JSON or CSV row files used by **File → Import…**;
- open or repair the local NeoAnki2 library;
- preserve or transfer review history; or
- support Anki `.apkg` or `.colpkg` packages.

Use the app's **File → Import Deck…** after validation. Import remains
all-or-nothing and allocates fresh deck, item, and card identifiers.

## Internal fixture command

The executable also contains:

```text
neoanki-deck generate-ui-fixtures <output-directory>
```

This is an **internal development command** for generating UI-test fixture
files such as sample portable decks. It creates and writes files in the output
directory and is not part of the authored-deck validation or normal user
workflow. Do not use it to convert personal decks, validate content, back up a
library, or prepare a production import.

For the authored source layout and all supported records, see the
[Authored Deck Format](../../AUTHORED_DECK_FORMAT.html).
