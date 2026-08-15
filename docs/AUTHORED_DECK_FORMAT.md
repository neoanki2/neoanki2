---
title: Authored deck format
description: Implement or inspect editable .neoanki bundles, records, validation rules, and safety limits.
parent: Reference
---

# NeoAnki Authored Deck Format (`.neoanki`)

## 1. Status and purpose

This document is the normative specification for NeoAnki Authored Deck Format
version 4. The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**,
**SHOULD NOT**, and **MAY** are interpreted as in RFC 2119 and RFC 8174.

The format is an import-only, text-based source representation for coding
agents and humans. It can declare deck trees, item types, templates, items,
tags, and local media. It never contains cards, scheduling state, review
history, statistics, or stable library identifiers.

An authored deck is not `.neodeck`. `.neoanki` is editable source; `.neodeck`
is the SQLite-based portable interchange format.

## 2. Bundle layout

An authored deck MUST be a regular, non-symlink directory whose name ends in
`.neoanki`:

```text
Biology.neoanki/
  deck.jsonl
  items/
    cells-001.jsonl
  media/
    cell.webp
```

`deck.jsonl` is REQUIRED. Item-part paths are explicitly listed by the manifest.
The `media/` directory is optional. Source and media paths MUST remain inside
the bundle. URLs, absolute paths, `..`, symlinks, globs, recursive discovery,
macros, and executable includes are forbidden.

Every source file MUST be UTF-8 without a byte-order mark. Each nonblank line
MUST be one complete JSON object. Comments, trailing commas, `NaN`, and
infinities are invalid. Object member names MUST be unique. Unknown members
are errors.

## 3. Common representations

Author-visible identifiers match:

```text
[A-Za-z][A-Za-z0-9_-]{0,63}
```

Identifiers are local to one bundle. They are references, not display names,
UUIDs, or provenance. Import allocates fresh UUIDs.

Names and tags MUST be non-empty after Unicode whitespace trimming. Names and
tags are limited to 1,024 UTF-8 bytes. JSON array order is semantic for fields,
templates, slots, rich spans, and tags.

## 4. Manifest and source parts

`deck.jsonl` MUST contain exactly one manifest record:

```json
{"kind":"neoanki","version":3,"root":"biology","parts":["items/cells-001.jsonl"]}
```

Members are exact:

- `kind`: `"neoanki"`;
- `version`: integer `3`;
- `root`: identifier of the root deck; and
- `parts`: ordered, unique relative paths to `.jsonl` item files.

`deck.jsonl` may otherwise contain only `type` and `deck` records. Item parts
may contain only `item` records. Record declaration order does not affect name
resolution.

## 5. Deck records

```json
{"kind":"deck","id":"biology","name":"Biology","itemTypes":["Basic","Cloze"],"defaultType":"Basic"}
{"kind":"deck","id":"cells","name":"Cells","parent":"biology"}
```

`parent` is omitted or `null` only on the manifest root deck. Every other deck
MUST reference a declared parent. Identifiers are unique and the hierarchy
MUST be acyclic and connected to the root.

In version 3 and later the root deck MUST declare a non-empty, ordered `itemTypes` array.
A descendant MAY declare its own non-empty array; omission inherits the
nearest ancestor declaration. Optional `defaultType` MUST reference the same
record's `itemTypes` array. One available type is selected automatically.
Multiple types without a default deliberately require the user to choose.

Every type record in a version-3 bundle is included with the imported root,
even when no deck policy offers it for new items. Included definitions stay
out of the ordinary Item Types list until the user unlocks one for in-place
editing or explicitly duplicates one as an independent definition.

## 6. Item-type records

```json
{
  "kind": "type",
  "id": "Basic",
  "name": "Basic",
  "fields": [
    {"id":"front","name":"Front","type":"text","required":true},
    {"id":"back","name":"Back","type":"richText"}
  ],
  "templates": [
    {
      "name":"Forward",
      "prompt":[{"field":"front"}],
      "answer":[{"field":"back"}],
      "interaction":"reveal",
      "skill":{"input":"text","output":"text","operation":"recall"}
    }
  ]
}
```

Field `required` defaults to `false`. Field types are `text`, `richText`,
`audio`, `image`, `gif`, `video`, `number`, and `cloze`. Field identifiers are
unique within their type. Every type needs at least one field and template.

### 6.1 Template slots

A slot has exactly one source:

```json
{"field":"front"}
{"literal":"Translate: "}
```

Optional `reveal` is `always`, `hiddenUntilAnswer`, or `blurred`; it defaults
to `always`. Optional `media` is `default`, `autoplay`, `playOnTap`, or `loop`;
it defaults to `default`. Non-default media behavior is valid only on audio,
GIF, or video fields.

`interaction` is `reveal`, `type`, `choose`, `record`, `audioSubmission`, `cloze`, or `arrange`.
An `audioSubmission` template MUST contain at least one prompt slot, MUST have an
empty answer side, and MUST declare `audio` as its skill output. Learner
recordings are local library data and are never part of an authored bundle.

`skill.input` and `skill.output` are `text`, `audio`, `image`, `video`,
`diagram`, `none`, `freeResponse`, `selection`, `spatial`, or `sequence`.
`skill.operation` is `recognize`, `recall`, `discriminate`, `classify`,
`locate`, `order`, `apply`, `explain`, or `reproduce`.

### 6.2 Generation conditions

`generateWhen` is optional. It is exactly one of:

```json
{"fieldNotEmpty":"audio"}
{"fieldEmpty":"hint"}
{"all":[{"fieldNotEmpty":"front"},{"fieldNotEmpty":"back"}]}
{"any":[{"fieldNotEmpty":"image"},{"fieldNotEmpty":"audio"}]}
```

Condition arrays are non-empty. Every field reference resolves within the
owning type. Nesting depth is limited to 64.

## 7. Item records and values

```json
{
  "kind":"item",
  "deck":"cells",
  "type":"Basic",
  "fields":{
    "front":{"text":"What powers the cell?","lang":"en"},
    "back":{"rich":[{"text":"The "},{"text":"mitochondrion","styles":["bold"]}]}
  },
  "tags":["biology"]
}
```

`deck` and `type` MUST resolve. `fields` keys are source field identifiers.
Unknown fields are errors. A missing optional field or explicit JSON `null`
means empty. Required fields MUST have a non-empty value. `tags` is optional.

Values are selected by the declared field type:

```json
{% raw %}
{"text":"plain text"}
{"text":"hola","lang":"es"}
{"rich":[{"text":"important","styles":["bold","superscript"],"color":"purple","size":"large","link":"https://example.com"}]}
{"number":42.5}
{"cloze":"Paris is in {{c1::France::country}}."}
{"media":{"path":"media/paris.webp","alt":"Map of Paris","durationMs":1200}}
{% endraw %}
```

Rich styles are `bold`, `italic`, `underline`, `strikethrough`, `highlight`,
`code`, `superscript`, and `subscript`; styles cannot repeat within a span.
For compatibility with older hand-authored content, a span containing both
`highlight` and `code` is normalized to `highlight`, and one containing both
`superscript` and `subscript` is normalized to `superscript`. Writers SHOULD
emit only the normalized style.
A span may also have a semantic `color` (`red`, `orange`, `yellow`, `green`,
`mint`, `teal`, `cyan`, `blue`, `indigo`, `purple`, `pink`, `brown`, or
`gray`), a relative `size` (`small` or `large`), and an absolute `http`,
`https`, or `mailto` `link` of at most 2,048 UTF-8 bytes. These additions
require manifest version 2. JSON Schema `maxLength` counts Unicode characters,
so the compiler performs the authoritative UTF-8 byte-limit and URL host/path
validation.

Cloze markers have the form {% raw %}`{{cN::answer}}` or
`{{cN::answer::hint}}`{% endraw %}, where `N` is a positive integer and `answer` is
non-empty. Import removes the marker syntax and computes Unicode
extended-grapheme-cluster offsets. Markers cannot nest; answers and hints
cannot contain `::` or `}}`.

`durationMs` is optional and non-negative. `alt` is optional. The declared
field determines media kind.

## 8. Media

Media paths MUST begin with `media/`, resolve to regular files beneath the
bundle's `media/` directory, and remain there after symlink resolution.

NeoAnki verifies extension, file signature, kind, and size; extensions alone
are not trusted. Supported formats are:

- image: `png`, `jpg`/`jpeg`, `heic`, `webp`, `tiff`;
- GIF: `gif`;
- audio: `m4a`, `mp3`, `wav`, `aac`, `caf`; and
- video: `mp4`, `mov`, `m4v`.

HTML, SVG, scripts, playlists, remote URLs, and embedded base64 are forbidden.
Media is hashed with SHA-256, deduplicated by verified bytes, reverified
immediately before adoption, and copied in bounded chunks.

## 9. Validation and limits

Default implementation limits include:

- 64 MB per source file and 64 MB across all JSONL source files;
- 1 MiB per JSONL record;
- 1,000 item parts;
- 1,000 decks;
- 256 item types;
- 256 fields and 256 templates per type;
- 100,000 items;
- 256 tags per item;
- 4,096 rich spans;
- 20 MB audio, 10 MB image, 15 MB GIF, and 100 MB video;
- 10,000 media assets; and
- 500 MB total media.

Implementations MAY impose lower limits. Counts, sizes, and sums are checked
before mutation with overflow-safe arithmetic.

Validation is all-or-nothing. Syntax, exact members, identifiers, references,
deck topology, type semantics, field values, cloze markers, limits, and media
are checked before the destination transaction.

## 10. Import semantics

Import allocates fresh deck and item UUIDs and generates fresh cards through
the destination's normal `CardGenerator`. Scheduling starts never-reviewed.

Authored types carry no provenance. An exact canonical schema digest reuses the
lexicographically first matching local type; otherwise import creates a type.
Changing a schema creates a distinct type. Re-import creates duplicate content
but reuses an unchanged schema. Digest reuse never removes an existing type's
ordinary, reusable Item Type status.

Version-3 types and deck policies are imported contextually. Version-1 and
version-2 bundles keep their historical behavior: imported types become normal
Item Types and no deck policy is created.

Media is staged through reservation records. Item types, decks, items, cards,
and media references commit in one database transaction. Any failure rolls
back the database and media reservations.

## 11. Validation command

From the repository:

```bash
swift run --package-path NeoAnkiCore neoanki-deck validate path/to/Biology.neoanki
```

Success exits zero. Failure exits nonzero and emits stable compiler-style
diagnostics:

```text
Biology.neoanki/items/cells-001.jsonl:18: AD222: Item contains unknown field "backs".
```

## 12. Evolution

Version 4 adds `audioSubmission` templates. Version 3 adds deck item-type policies and included item types. Version 2 adds
portable inline text color, relative size, links, superscript, and subscript.
Versions 1 and 2 remain readable; their imported types retain the legacy global
behavior. Version 1 cannot use the version-2 text members or styles. Writers
MUST NOT add members or record kinds not defined here.
Incompatible changes increment the manifest `version`; importers MUST reject
unsupported versions rather than guessing.
