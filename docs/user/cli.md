---
title: Deck authoring CLI
description: Build and run neoanki-deck to validate editable authored deck bundles before import.
audience: user
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
- version-3 root and descendant item-type policies, including ordered
  references and valid defaults;
- item values, tags, required fields, rich text, and cloze markers;
- media paths, confinement, signatures, kinds, sizes, and aggregate limits; and
- source-file, record, part, deck, type, field, template, item, and media
  limits.

Rich-text values may use the version 2 span format to preserve supported
styles, semantic text colors, relative text sizes, and safe HTTP, HTTPS, or
mailto links. The validator also accepts legacy version 1 rich text; conflicting
legacy style pairs are normalized during import.

For new bundles, use manifest version 5. The root deck must provide a
non-empty `itemTypes` array; add `defaultType` when one choice should be
recommended. Descendants inherit the nearest declaration unless they provide
their own non-empty array.

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

NeoAnki2 also reuses this authored-bundle validation and atomic import boundary
when an installed offline vocabulary pack generates items for an existing
deck. That app workflow does not change the CLI command or its diagnostics.

## Migrate a version-1 template library

The one-shot `neoanki-template-migrator` upgrades a local library from stored
prompt/answer sides to template definition format 2. Keep NeoAnki2 closed and
back up both the database and media directory first:

```bash
swift run neoanki-template-migrator plan --database /path/to/neoanki2.sqlite
swift run neoanki-template-migrator apply --database /path/to/neoanki2.sqlite
swift run neoanki-template-migrator verify --database /path/to/neoanki2.sqlite
```

`plan` reads item-type definitions only and reports structural mappings.
`apply` rejects broken field references, validates every transformed item type,
preserves item/template/card/review/response/media identities, refreshes
digests and change records, and performs one atomic commit. `verify` checks the
format marker, references, counts, and SQLite integrity. The app deliberately
contains no runtime decoder for the earlier definition format.

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
[Authored Deck Format]({{ site.baseurl }}/AUTHORED_DECK_FORMAT/).
