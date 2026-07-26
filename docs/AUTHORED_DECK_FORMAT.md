# NeoAnki Authored Deck Format (`.neoanki`)

## 1. Status and purpose

This document is the normative specification for NeoAnki Authored Deck Format
version 1. The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**,
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
{"kind":"neoanki","version":1,"root":"biology","parts":["items/cells-001.jsonl"]}
```

Members are exact:

- `kind`: `"neoanki"`;
- `version`: integer `1`;
- `root`: identifier of the root deck; and
- `parts`: ordered, unique relative paths to `.jsonl` item files.

`deck.jsonl` may otherwise contain only `type` and `deck` records. Item parts
may contain only `item` records. Record declaration order does not affect name
resolution.

## 5. Deck records

```json
{"kind":"deck","id":"cells","name":"Cells","parent":"biology"}
```

`parent` is omitted or `null` only on the manifest root deck. Every other deck
MUST reference a declared parent. Identifiers are unique and the hierarchy
MUST be acyclic and connected to the root.

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

`interaction` is `reveal`, `type`, `choose`, `record`, `cloze`, or `arrange`.

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
{"text":"plain text"}
{"text":"hola","lang":"es"}
{"rich":[{"text":"important","styles":["bold","highlight"]}]}
{"number":42.5}
{"cloze":"Paris is in {{c1::France::country}}."}
{"media":{"path":"media/paris.webp","alt":"Map of Paris","durationMs":1200}}
```

Rich styles are `bold`, `italic`, `underline`, `strikethrough`, `highlight`,
and `code`; styles cannot repeat within a span.

Cloze markers have the form `{{cN::answer}}` or
`{{cN::answer::hint}}`, where `N` is a positive integer and `answer` is
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
but reuses an unchanged schema.

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

Version 1 is closed: writers MUST NOT add members or record kinds not defined
here. Incompatible changes increment the manifest `version`. Importers MUST
reject unsupported versions rather than guessing.
